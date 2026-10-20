<?php
/**
 * Explicit, local Joomla MCP identity enrollment through Joomla's native APIs.
 *
 * Run as the service owner, with the input and output outside the public site.
 * Credentials never go into arguments or stdout. A repeat invocation preserves
 * the existing identity/token and refuses unrelated accounts or changed grants.
 */
declare(strict_types=1);

use Joomla\CMS\Access\Access;
use Joomla\CMS\Event\Model\PrepareDataEvent;
use Joomla\CMS\Factory;
use Joomla\CMS\Plugin\PluginHelper;
use Joomla\CMS\Table\Asset;
use Joomla\CMS\Table\Extension;
use Joomla\CMS\Table\Usergroup;
use Joomla\CMS\User\User;
use Joomla\CMS\User\UserHelper;
use Joomla\Database\DatabaseInterface;
use Joomla\Registry\Registry;

final class EnrollmentError extends RuntimeException {}

function demand(bool $condition, string $message): void
{
    if (!$condition) {
        throw new EnrollmentError($message);
    }
}

/** Read a private regular file without following links or accepting hard links. */
function privateJson(string $path): array
{
    $before = @lstat($path);
    demand(is_array($before) && ($before['mode'] & 0170000) === 0100000
        && ($before['mode'] & 0077) === 0 && $before['uid'] === posix_geteuid()
        && $before['nlink'] === 1 && $before['size'] <= 65536, 'Input must be an owned private regular file.');
    $stream = fopen($path, 'rb');
    demand($stream !== false, 'Cannot open enrollment input.');
    try {
        $after = fstat($stream);
        demand($after['dev'] === $before['dev'] && $after['ino'] === $before['ino'], 'Input changed while opening.');
        $value = json_decode(stream_get_contents($stream, 65537), true, 32, JSON_THROW_ON_ERROR);
    } finally {
        fclose($stream);
    }
    demand(is_array($value) && !array_is_list($value), 'Input must be a JSON object.');
    return $value;
}

/** Validate all operator input before opening Joomla or modifying any state. */
function validateEnrollment(array $input): array
{
    $keys = ['schema', 'service_id', 'api_base', 'site_alias', 'client', 'artifact_directory'];
    demand(array_diff(array_keys($input), $keys) === [] && ($input['schema'] ?? null) === 1, 'Unsupported enrollment document.');
    foreach (['service_id', 'site_alias'] as $name) {
        demand(is_string($input[$name] ?? null) && preg_match('/\A[a-z][a-z0-9_-]{0,63}\z/D', $input[$name]) === 1, 'Invalid service or site identity.');
    }
    demand(is_string($input['api_base'] ?? null), 'Canonical API URL is required.');
    $url = parse_url($input['api_base']);
    demand(is_array($url) && ($url['scheme'] ?? '') === 'https' && !empty($url['host'])
        && !isset($url['user'], $url['pass']) && !isset($url['user']) && !isset($url['pass'])
        && !isset($url['query']) && !isset($url['fragment'])
        && preg_match('#\A(?:/[A-Za-z0-9._~-]+)*/api/index\.php\z#D', $url['path'] ?? '') === 1
        && !str_contains($input['api_base'], '..') && !preg_match('/[\x00-\x20\x7f]/', $input['api_base']),
        'Canonical API URL must be an HTTPS URL ending in /api/index.php.');
    demand(($input['artifact_directory'] ?? null) === '/var/lib/joomengine-mcp/artifacts', 'Unexpected private artifact directory.');
    $client = $input['client'] ?? null;
    demand(is_array($client) && !array_is_list($client), 'Client identity is required.');
    demand(array_diff(array_keys($client), ['id', 'username', 'name', 'email', 'password', 'permissions']) === [], 'Unknown client field.');
    demand(is_string($client['id'] ?? null) && preg_match('/\A[a-z][a-z0-9_-]{0,63}\z/D', $client['id']) === 1, 'Invalid client identifier.');
    demand(is_string($client['username'] ?? null) && preg_match('/\A[A-Za-z0-9][A-Za-z0-9_.@-]{2,99}\z/D', $client['username']) === 1, 'Invalid client username.');
    demand(is_string($client['name'] ?? null) && strlen($client['name']) >= 1 && strlen($client['name']) <= 150
        && !preg_match('/[\x00-\x1f\x7f]/', $client['name']), 'Invalid client name.');
    demand(is_string($client['email'] ?? null) && filter_var($client['email'], FILTER_VALIDATE_EMAIL) !== false, 'Invalid client email.');
    demand(is_string($client['password'] ?? null) && strlen($client['password']) >= 32 && strlen($client['password']) <= 1024
        && !preg_match('/[\x00-\x1f\x7f]/', $client['password']), 'A generated password of at least 32 characters is required.');
    $permissions = $client['permissions'] ?? [];
    demand(is_array($permissions) && count($permissions) <= 32, 'Invalid permission map.');
    foreach ($permissions as $asset => $rules) {
        demand(is_string($asset) && preg_match('/\Acom_[a-z0-9_]+(?:\.[a-zA-Z0-9_-]+)*\z/D', $asset) === 1
            && is_array($rules) && count($rules) <= 64, 'Only explicit component assets may be granted.');
        foreach ($rules as $action => $allowed) {
            demand(is_string($action) && preg_match('/\A[a-z][a-z0-9_.-]{0,99}\z/D', $action) === 1
                && $allowed === true, 'Permission entries must be explicit named grants.');
            demand($action !== 'core.login.admin', 'Administrator login cannot be granted to an API identity.');
            demand($action !== 'core.admin' || in_array($asset, ['com_componentbuilder', 'com_installer'], true),
                'Administrator grants are limited to explicitly selected JCB or installer component authority.');
        }
        ksort($permissions[$asset]);
    }
    ksort($permissions);
    $input['client']['permissions'] = $permissions;
    return $input;
}

function saveTable(object $table, string $operation): void
{
    // Keep database/extension error strings out of logs: they can contain inputs.
    demand($table->check() && $table->store(), 'Joomla refused ' . $operation . '.');
}

function extension(DatabaseInterface $db, string $type, string $element, string $folder = ''): Extension
{
    $table = new Extension($db);
    demand($table->load(['type' => $type, 'element' => $element, 'folder' => $folder]), 'A required Joomla extension is not installed.');
    return $table;
}

/** Apply only this client's group rules; all unrelated rules remain intact. */
function grant(DatabaseInterface $db, string $name, int $groupId, array $actions): void
{
    $asset = new Asset($db);
    demand($asset->load(['name' => $name]), 'A configured permission asset does not exist.');
    $rules = json_decode((string) $asset->rules, true, 32, JSON_THROW_ON_ERROR);
    foreach ($actions as $action => $allowed) {
        $rules[$action][(string) $groupId] = $allowed;
    }
    $asset->rules = json_encode($rules, JSON_THROW_ON_ERROR);
    saveTable($asset, 'a scoped permission update');
}

function enrollmentMain(array $arguments): void
{
    demand(PHP_SAPI === 'cli' && function_exists('posix_geteuid'), 'Enrollment requires the PHP CLI with POSIX support.');
    $options = getopt('', ['input:', 'output:', 'validate-only']);
    demand(isset($options['input'], $options['output']) && count($arguments) >= 5, 'Usage: php joomengine-bootstrap.php --input FILE --output FILE');
    $input = validateEnrollment(privateJson((string) $options['input']));
    if (isset($options['validate-only'])) {
        fwrite(STDOUT, "Enrollment input is valid.\n");
        return;
    }
    demand(posix_geteuid() === 0, 'Enrollment requires the local service owner.');
    $output = (string) $options['output'];
    $parent = dirname($output);
    $stat = @lstat($parent);
    demand($parent === '/run/ductor-output' && realpath($parent) === $parent && is_array($stat)
        && ($stat['mode'] & 0170000) === 0040000 && ($stat['mode'] & 0077) === 0 && $stat['uid'] === 0,
        'Output requires the private /run/ductor-output directory.');
    demand(basename($output) === 'client.json', 'Unexpected client output filename.');
    if (file_exists($output) || is_link($output)) {
        $previous = privateJson($output);
        demand(($previous['service_id'] ?? null) === $input['service_id']
            && ($previous['client_id'] ?? null) === $input['client']['id'], 'Output belongs to a different client.');
    }
    umask(0077);
    $lock = fopen($parent . '/.enrollment.lock', 'c');
    demand($lock !== false && flock($lock, LOCK_EX | LOCK_NB), 'Another enrollment is running.');
    $root = '/var/www/html';
    demand(is_file($root . '/configuration.php'), 'Joomla must be installed before client enrollment.');
    // Third-party user plugins must not accidentally print enrollment data.
    ob_start();
    define('_JEXEC', 1);
    define('JPATH_BASE', $root);
    require $root . '/includes/defines.php';
    require $root . '/includes/framework.php';
    ini_set('display_errors', '0');
    // Match the native Joomla CLI bootstrap, without executing arbitrary commands.
    $container = Factory::getContainer();
    $container->alias('session', 'session.cli')
        ->alias(Joomla\CMS\Session\Session::class, 'session.cli')
        ->alias(Joomla\Session\Session::class, 'session.cli')
        ->alias(Joomla\Session\SessionInterface::class, 'session.cli');
    $app = $container->get(Joomla\Console\Application::class);
    Factory::$application = $app;
    $app->createExtensionNamespaceMap();
    $url = parse_url($input['api_base']);
    $_SERVER['HTTP_HOST'] = $url['host'] . (isset($url['port']) ? ':' . $url['port'] : '');
    $_SERVER['REQUEST_URI'] = $url['path'];
    $_SERVER['HTTPS'] = 'on';
    $db = $container->get(DatabaseInterface::class);
    $client = $input['client'];
    $owner = 'ductor:' . $input['service_id'] . ':' . $client['id'];
    $groupTitle = 'Ductor MCP ' . substr($input['service_id'], 0, 40) . ' ' . substr(hash('sha256', $owner), 0, 20);
    $permissionsHash = hash('sha256', json_encode($client['permissions'], JSON_THROW_ON_ERROR));
    $db->transactionStart();
    try {
        $mcp = extension($db, 'component', 'com_joomengine_mcp');
        $params = new Registry($mcp->params);
        $existingOwner = $params->get('ductor_service_id');
        demand($existingOwner === null || $existingOwner === $input['service_id'], 'MCP configuration belongs to another deployment.');
        $oldApi = $params->get('api_base', '');
        demand($oldApi === '' || $oldApi === $input['api_base'], 'Canonical API URL changed; migrate it explicitly.');
        $params->set('ductor_service_id', $input['service_id']);
        $params->set('api_base', $input['api_base']);
        $params->set('site_alias', $input['site_alias']);
        $params->set('php_cli_binary', PHP_BINARY);
        $params->set('artifact_directory', $input['artifact_directory']);
        $params->set('allow_indefinite', 0);
        $mcp->params = $params->toString();
        saveTable($mcp, 'MCP configuration');
        foreach ([['webservices', 'joomengine_mcp'], ['console', 'joomengine_mcp'], ['api-authentication', 'token']] as [$folder, $element]) {
            $plugin = extension($db, 'plugin', $element, $folder);
            $plugin->enabled = 1;
            saveTable($plugin, 'a required plugin activation');
        }
        $public = new Usergroup($db);
        demand($public->load(['parent_id' => 0]), 'Joomla public group is unavailable.');
        $group = new Usergroup($db);
        $groupExists = $group->load(['title' => $groupTitle]);
        $userId = (int) UserHelper::getUserId($client['username']);
        $user = new User($userId);
        if ($userId > 0) {
            demand($user->getParam('ductor_owner') === $owner && $groupExists
                && (int) $group->parent_id === (int) $public->id
                && array_values(array_map('intval', $user->groups)) === [(int) $group->id]
                && !$user->block && !$user->requireReset
                && $user->getParam('ductor_permissions_sha256') === $permissionsHash,
                'Existing account, group or permissions differ; refusing implicit adoption or privilege change.');
        } else {
            demand(!$groupExists, 'A same-named group already exists; refusing implicit adoption.');
            $group->bind(['title' => $groupTitle, 'parent_id' => (int) $public->id]);
            saveTable($group, 'a dedicated client group');
        }
        $groupId = (int) $group->id;
        $tokenPlugin = extension($db, 'plugin', 'token', 'user');
        $tokenParams = new Registry($tokenPlugin->params);
        $allowed = $tokenParams->get('allowedUserGroups', [8]);
        // Empty means all groups in Joomla; preserve that existing site policy.
        if (!empty($allowed)) {
            $allowed = array_values(array_unique(array_merge(array_map('intval', (array) $allowed), [$groupId])));
            $tokenParams->set('allowedUserGroups', $allowed);
        }
        $tokenPlugin->params = $tokenParams->toString();
        $tokenPlugin->enabled = 1;
        saveTable($tokenPlugin, 'the token plugin group scope');
        if ($userId === 0) {
            $userData = ['username' => $client['username'], 'name' => $client['name'], 'email' => $client['email'],
                'password' => $client['password'], 'password2' => $client['password'], 'groups' => [$groupId],
                'block' => 0, 'sendEmail' => 0, 'requireReset' => 0];
            demand($user->bind($userData), 'Joomla refused the client identity fields.');
            $user->setParam('ductor_owner', $owner);
            $user->setParam('ductor_permissions_sha256', $permissionsHash);
            demand($user->save(), 'Joomla refused the dedicated client account.');
        }
        grant($db, 'root.1', $groupId, ['core.login.api' => true, 'core.login.site' => false, 'core.login.admin' => false]);
        grant($db, 'com_joomengine_mcp', $groupId, ['mcp.access' => true, 'mcp.execute' => true]);
        foreach ($client['permissions'] as $asset => $rules) {
            grant($db, $asset, $groupId, $rules);
        }
        Access::clearStatics();
        $user = new User((int) $user->id);
        demand(!$user->authorise('core.admin') && $user->authorise('core.login.api')
            && !$user->authorise('core.login.admin') && !$user->authorise('core.login.site')
            && $user->authorise('mcp.access', 'com_joomengine_mcp') && $user->authorise('mcp.execute', 'com_joomengine_mcp'),
            'Effective native Joomla permissions do not match the enrolled identity.');
        demand($user->authorise('mcp.write', 'com_joomengine_mcp') === ($client['permissions']['com_joomengine_mcp']['mcp.write'] ?? false),
            'Inherited write permission differs from the explicit enrollment scope.');
        $app->loadIdentity($user);
        PluginHelper::importPlugin('user', 'token', true, $app->getDispatcher());
        $data = (object) ['id' => (int) $user->id];
        $event = new PrepareDataEvent('onContentPrepareData', ['context' => 'com_users.profile', 'data' => $data]);
        $app->getDispatcher()->dispatch('onContentPrepareData', $event);
        $data = $event->getData();
        $token = $data->joomlatoken['token'] ?? '';
        demand(is_string($token) && strlen($token) >= 32 && !preg_match('/[\x00-\x20\x7f]/', $token),
            'Native Joomla token is disabled or unavailable; re-enable it explicitly in Joomla.');
        $payload = ['schema' => 1, 'service_id' => $input['service_id'], 'client_id' => $client['id'],
            'username' => $client['username'], 'user_id' => (int) $user->id,
            'write_enabled' => $user->authorise('mcp.write', 'com_joomengine_mcp'),
            'url' => $input['api_base'] . '/v1/joomengine-mcp', 'alias' => $input['site_alias'], 'token' => $token];
        $db->transactionCommit();
    } catch (Throwable $error) {
        $db->transactionRollback();
        throw $error;
    }
    $temp = tempnam($parent, '.client-');
    demand($temp !== false && chmod($temp, 0600), 'Cannot create private credential output.');
    try {
        demand(file_put_contents($temp, json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n") !== false
            && rename($temp, $output), 'Cannot publish private credential output.');
    } finally {
        if (is_file($temp)) {
            unlink($temp);
        }
    }
    ob_end_clean();
    fwrite(STDOUT, "Dedicated Joomla MCP identity enrolled; credentials written to the private output file.\n");
}

try {
    enrollmentMain($argv);
} catch (Throwable $error) {
    while (ob_get_level() > 0) {
        ob_end_clean();
    }
    // Do not emit exception details/stack traces: extension errors can contain secrets.
    fwrite(STDERR, "Joomla MCP enrollment failed: " . ($error instanceof EnrollmentError ? $error->getMessage() : 'native operation failed') . "\n");
    exit(1);
}

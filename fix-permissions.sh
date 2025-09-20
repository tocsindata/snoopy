#!/usr/bin/env php
<?php
/**
 * fix-permissions.php — make every /home/USER/public_html site behave like cPanel/Softaculous.
 * - One UNIX user per site (directory name under /home)
 * - PHP-FPM pool runs AS that user, with its own unix socket
 * - Apache proxies PHP for that docroot to that socket
 * - Filesystem: dirs 755, files 644, owner USER:USER
 * - Idempotent: prints OK when no changes are needed
 *
 * Run as root:  php fix-permissions.php  (or chmod +x and run directly)
 */

error_reporting(E_ALL);
ini_set('display_errors', 'stderr');

function sh($cmd, &$out=null, &$code=null) {
    $out = [];
    exec($cmd . ' 2>&1', $out, $code);
    return $code === 0;
}
function file_put_contents_if_changed($path, $content, $mode = 0644, $ownerUser=null, $ownerGroup=null) {
    $changed = !is_file($path) || file_get_contents($path) !== $content;
    if ($changed) {
        if (!is_dir(dirname($path))) {
            mkdir(dirname($path), 0755, true);
        }
        file_put_contents($path, $content);
        chmod($path, $mode);
        if ($ownerUser !== null && $ownerGroup !== null) {
            @chown($path, $ownerUser);
            @chgrp($path, $ownerGroup);
        }
        echo "[FIXED] wrote ". $path . PHP_EOL;
    } else {
        echo "[OK]    ". $path . PHP_EOL;
    }
    return $changed;
}
function is_debian_like() {
    return is_file('/etc/debian_version') || is_dir('/etc/apt');
}
function is_rhel_like() {
    return is_file('/etc/redhat-release') || is_dir('/etc/yum.repos.d') || is_dir('/etc/dnf');
}
function detect_web_group() {
    // Only used for socket file readability; Apache still runs as www-data/apache.
    if (is_debian_like()) return 'www-data';
    if (is_rhel_like())   return 'apache';
    // fallback
    return 'www-data';
}
function detect_php_fpm_version() {
    // Prefer highest installed FPM on Debian-style /etc/php/*/fpm
    $candidates = [];
    foreach (glob('/etc/php/*/fpm', GLOB_ONLYDIR) ?: [] as $dir) {
        $v = basename(dirname($dir)); // e.g., 8.3
        if (preg_match('/^\d+\.\d+$/', $v)) $candidates[] = $v;
    }
    if ($candidates) {
        usort($candidates, 'version_compare');
        return end($candidates); // highest
    }
    // RHEL-ish: try to read `php-fpm -v`
    $out = [];
    if (sh('php-fpm -v', $out)) {
        if (preg_match('/PHP\s+(\d+\.\d+)\./', implode("\n", $out), $m)) return $m[1];
    }
    // fallback to 8.3
    return '8.3';
}
function service_reload($name) {
    // Try systemctl, then service
    $out=[]; $code=0;
    if (sh("systemctl reload $name", $out, $code)) return true;
    if (sh("systemctl restart $name", $out, $code)) return true;
    if (sh("service $name reload", $out, $code))   return true;
    if (sh("service $name restart", $out, $code))  return true;
    echo "[WARN] Failed to reload/restart $name: ".implode(' | ',$out).PHP_EOL;
    return false;
}
function ensure_mode($path, $mode) {
    if (!file_exists($path)) return false;
    $cur = fileperms($path) & 0777;
    if ($cur !== $mode) {
        chmod($path, $mode);
        echo "[FIXED] chmod ".decoct($mode)." $path".PHP_EOL;
        return true;
    }
    echo "[OK]    mode ".decoct($mode)." $path".PHP_EOL;
    return false;
}
function ensure_owner($path, $user, $group, $recursive=false) {
    if (!file_exists($path)) return false;
    $changed = false;
    if ($recursive) {
        // chown/chgrp recursively via shell for speed
        sh("chown -R ".escapeshellarg("$user:$group")." ".escapeshellarg($path));
        echo "[FIXED] chown -R $user:$group $path".PHP_EOL;
        return true;
    } else {
        $stat = @stat($path);
        $u = $stat ? posix_getpwuid($stat['uid'])['name'] ?? null : null;
        $g = $stat ? posix_getgrgid($stat['gid'])['name'] ?? null : null;
        if ($u !== $user || $g !== $group) {
            @chown($path, $user);
            @chgrp($path, $group);
            echo "[FIXED] chown $user:$group $path".PHP_EOL;
            $changed = true;
        } else {
            echo "[OK]    owner $user:$group $path".PHP_EOL;
        }
        return $changed;
    }
}

if (posix_geteuid() !== 0) {
    fwrite(STDERR, "Run as root.\n");
    exit(1);
}

$webGroup = detect_web_group();
$phpMinor = detect_php_fpm_version();
$phpFpmService = is_debian_like() ? "php{$phpMinor}-fpm" : "php-fpm";
$apacheService = is_debian_like() ? "apache2" : "httpd";
$apacheConfDir  = is_debian_like() ? "/etc/apache2" : "/etc/httpd";
$perSiteConfDir = is_debian_like() ? "$apacheConfDir/conf-available" : "$apacheConfDir/conf.d";
$perSiteConfEnableCmd = function($confFileBasename) use ($apacheConfDir) {
    // Debian a2enconf, RHEL auto-loads conf.d
    if (is_debian_like()) {
        sh("a2enconf ".escapeshellarg($confFileBasename));
    }
    return true;
};

// Enable Apache modules when on Debian/Ubuntu
if (is_debian_like()) {
    sh('a2enmod proxy proxy_fcgi setenvif', $o, $c);
}

// Walk /home/* and process any dir that contains public_html
$homes = glob('/home/*', GLOB_ONLYDIR) ?: [];
$changedPools = false;
$changedApache = false;

foreach ($homes as $home) {
    $user = basename($home);
    $docroot = "$home/public_html";
    if (!is_dir($docroot)) {
        echo "[SKIP] $user (no public_html)\n";
        continue;
    }

    echo "=== Processing $user ($docroot) ===\n";

    // 1) Baseline ownership and perms (cpanel style)
    ensure_owner($home, $user, $user, true); // recursive
    // parent traversal
    ensure_mode('/home', 0755);
    ensure_mode($home, 0755);
    if (!is_dir($docroot)) { mkdir($docroot, 0755, true); echo "[FIXED] mkdir $docroot\n"; }
    ensure_mode($docroot, 0755);

    // Directories 755, Files 644 (under docroot)
    sh("find ".escapeshellarg($docroot)." -type d -exec chmod 755 {} \\;");
    sh("find ".escapeshellarg($docroot)." -type f -exec chmod 644 {} \\;");
    echo "[OK]    normalized perms under $docroot (dirs 755, files 644)\n";

    // 2) Per-site temp/log dirs
    $tmp = "$home/tmp";
    $sess = "$home/tmp/sessions";
    $logs = "$home/logs";
    foreach ([$tmp, $sess, $logs] as $d) {
        if (!is_dir($d)) { mkdir($d, 0700, true); echo "[FIXED] mkdir $d\n"; }
        ensure_owner($d, $user, $user);
        ensure_mode($d, 0700);
    }

    // 3) Ensure UserSpice common dirs exist (no file creation)
    $usersc = "$docroot/usersc";
    $includes = "$usersc/includes";
    $plugins  = "$usersc/plugins";
    $widgets  = "$usersc/widgets";
    foreach ([$usersc, $includes, $plugins, $widgets] as $d) {
        if (!is_dir($d)) { mkdir($d, 0755, true); echo "[FIXED] mkdir $d\n"; }
        ensure_owner($d, $user, $user);
        ensure_mode($d, 0755);
    }

    // 4) Per-site PHP-FPM pool (runs AS the site user)
    if (is_debian_like()) {
        $poolDir = "/etc/php/{$phpMinor}/fpm/pool.d";
        $poolFile = "$poolDir/{$user}.conf";
    } else {
        // RHEL-like: still use pool.d, versionless
        $poolDir = "/etc/php-fpm.d";
        $poolFile = "$poolDir/{$user}.conf";
    }
    if (!is_dir($poolDir)) { mkdir($poolDir, 0755, true); echo "[FIXED] mkdir $poolDir\n"; }

    $sock = "/run/php-fpm-{$user}.sock";
    $pool = <<<CONF
[{$user}]
user = {$user}
group = {$user}
listen = {$sock}
listen.owner = {$webGroup}
listen.group = {$webGroup}
pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 10s
chdir = {$docroot}
php_admin_value[open_basedir] = {$docroot}:/tmp
php_admin_value[upload_tmp_dir] = {$home}/tmp
php_admin_value[session.save_path] = {$home}/tmp/sessions
php_admin_value[error_log] = {$home}/logs/php-error.log

CONF;

    if (file_put_contents_if_changed($poolFile, $pool, 0644)) {
        $changedPools = true;
    }

    // 5) Apache routing for this docroot → that pool
    // We add a tiny include that only targets this docroot’s PHP files.
    if (is_debian_like()) {
        $siteConfBase = "php-fpm-{$user}.conf";
        $siteConfPath = "{$perSiteConfDir}/{$siteConfBase}";
    } else {
        $siteConfBase = "php-fpm-{$user}.conf";
        $siteConfPath = "{$perSiteConfDir}/{$siteConfBase}";
    }

    // Use FilesMatch inside a Directory block so it’s scoped to this docroot only.
    $apacheSnippet = <<<APC
# Managed by fix-permissions.php
<Directory "{$docroot}">
    AllowOverride All
    Require all granted
    <FilesMatch "\\.php$">
        SetHandler "proxy:unix:{$sock}|fcgi://localhost/"
    </FilesMatch>
</Directory>
APC;

    if (file_put_contents_if_changed($siteConfPath, $apacheSnippet, 0644)) {
        $changedApache = true;
        if (is_debian_like()) {
            $perSiteConfEnableCmd(basename($siteConfPath));
        }
    }

    echo "=== Done $user ===\n\n";
}

// Reload services only if needed
if ($changedPools) {
    echo "[INFO] Reloading PHP-FPM ($phpFpmService)\n";
    service_reload($phpFpmService);
} else {
    echo "[OK]    PHP-FPM pools already up to date\n";
}

if ($changedApache) {
    echo "[INFO] Reloading Apache\n";
    service_reload($apacheService);
} else {
    echo "[OK]    Apache config already up to date\n";
}

echo "All done.\n";

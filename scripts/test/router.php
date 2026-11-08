<?php

// Test double for ci-post, served by `php -S`. It records every request and
// answers /sequence with 401, 429, 503 and then 200, so a single ci-post run
// walks each retry branch; /reject always answers 422 and /created 201.

$state = getenv('CI_TEST_STATE');
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

if ($path === '/health') {
    http_response_code(204);

    return true;
}

$record = static function (string $name, string $line) use ($state): void {
    file_put_contents("{$state}/{$name}.log", $line.PHP_EOL, FILE_APPEND | LOCK_EX);
};

$record('authorization', $_SERVER['HTTP_AUTHORIZATION'] ?? '');
$record('method', $_SERVER['REQUEST_METHOD']);
$record('content-type', $_SERVER['CONTENT_TYPE'] ?? '');
$record('user-agent', $_SERVER['HTTP_USER_AGENT'] ?? '');
$record('ci-run', $_SERVER['HTTP_X_CI_RUN'] ?? '');
$record('ci-job', $_SERVER['HTTP_X_CI_JOB'] ?? '');
$record('body', file_get_contents('php://input'));
file_put_contents("{$state}/last-body", file_get_contents('php://input'));

// Keeps each curl process alive long enough for the test to sample its argv.
usleep(300000);

header('Content-Type: application/json');

if ($path === '/created') {
    http_response_code(201);
    echo '{"stored":true}';

    return true;
}

if ($path === '/reject') {
    http_response_code(422);
    echo '{"error":{"code":"rejected"}}';

    return true;
}

// /gateway answers 502 four times, past the old three-retry limit, then 200; /landed answers 502 and then 409,
// as a server does when the first attempt was stored and only its answer was lost; /broken always answers 500.
$calls = static function (string $name) use ($state): int {
    $file = "{$state}/{$name}.count";
    $seen = is_file($file) ? (int) file_get_contents($file) : 0;
    file_put_contents($file, (string) ($seen + 1));

    return $seen;
};

if ($path === '/gateway') {
    http_response_code($calls('gateway') < 4 ? 502 : 200);
    echo '{"ok":true}';

    return true;
}

if ($path === '/landed') {
    http_response_code($calls('landed') === 0 ? 502 : 409);
    echo '{"error":{"code":"replayed"}}';

    return true;
}

if ($path === '/conflict') {
    http_response_code(409);
    echo '{"error":{"code":"replayed"}}';

    return true;
}

if ($path === '/down') {
    $calls('down');
    http_response_code(502);
    echo '{"error":{"code":"down"}}';

    return true;
}

if ($path === '/broken') {
    $calls('broken');
    http_response_code(500);
    echo '{"error":{"code":"broken"}}';

    return true;
}

$counter = "{$state}/sequence.count";
$seen = is_file($counter) ? (int) file_get_contents($counter) : 0;
file_put_contents($counter, (string) ($seen + 1));

[$status, $retryAfter] = match ($seen) {
    0 => [401, null],
    1 => [429, '1'],
    2 => [503, '1'],
    default => [200, null],
};

http_response_code($status);

if ($retryAfter !== null) {
    header("Retry-After: {$retryAfter}");
}

echo $status === 200 ? '{"ok":true}' : '{"error":{"code":"retry"}}';

return true;

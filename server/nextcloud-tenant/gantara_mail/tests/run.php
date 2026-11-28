<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Dunetrails
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Unit tests for the pure parts of the app; no Nextcloud needed:
 *   php tests/run.php
 * With a Nextcloud tree (e.g. inside the image), also checks that the Mail and server methods the
 * app calls exist with the shapes it uses:
 *   php tests/run.php /var/www/html
 */

require __DIR__ . '/../lib/Service/AccountRequest.php';
require __DIR__ . '/../lib/Service/MailServers.php';

use OCA\GantaraMail\Service\AccountRequest;
use OCA\GantaraMail\Service\MailServers;

$failures = 0;
$count = 0;
function check(string $name, mixed $expected, mixed $actual): void {
	global $failures, $count;
	$count++;
	if ($expected !== $actual) {
		$failures++;
		fwrite(STDERR, "FAIL {$name}: expected " . var_export($expected, true) . ', got ' . var_export($actual, true) . "\n");
	}
}
function refuses(string $name, callable $f): void {
	try {
		$f();
		check($name, 'InvalidArgumentException', 'no exception');
	} catch (InvalidArgumentException) {
		check($name, true, true);
	}
}

// AccountRequest::forUpsert
$r = AccountRequest::forUpsert(' jan ', ' Jan.Peeters@GantaraMail.eu ', "Jan\tPeeters\n", 'a long secret 42');
check('uid trimmed', 'jan', $r->uid);
check('email lower-cased and trimmed', 'jan.peeters@gantaramail.eu', $r->email);
check('control characters in the name become spaces', 'Jan Peeters', $r->name);
check('password kept as given', 'a long secret 42', $r->password);
check('empty name falls back to the address', 'a@b.eu', AccountRequest::forUpsert('u', 'a@b.eu', '  ', 'x')->name);
check('long name cut at 255', 255, mb_strlen(AccountRequest::forUpsert('u', 'a@b.eu', str_repeat('é', 300), 'x')->name));
check('password with spaces at the ends is kept', ' x ', AccountRequest::forUpsert('u', 'a@b.eu', '', ' x ')->password);
refuses('empty uid', fn () => AccountRequest::forUpsert(' ', 'a@b.eu', '', 'x'));
refuses('uid too long', fn () => AccountRequest::forUpsert(str_repeat('u', 65), 'a@b.eu', '', 'x'));
refuses('not an address', fn () => AccountRequest::forUpsert('u', 'nope', '', 'x'));
refuses('address with a header break', fn () => AccountRequest::forUpsert('u', "a@b.eu\r\nBcc: c@d.eu", '', 'x'));
refuses('empty password', fn () => AccountRequest::forUpsert('u', 'a@b.eu', '', ''));
refuses('password too long', fn () => AccountRequest::forUpsert('u', 'a@b.eu', '', str_repeat('x', AccountRequest::MAX_PASSWORD + 1)));

// AccountRequest::forRemove
$d = AccountRequest::forRemove('jan', 'A@B.eu');
check('remove: address lower-cased', 'a@b.eu', $d->email);
check('remove: no password', '', $d->password);
refuses('remove: empty uid', fn () => AccountRequest::forRemove('', 'a@b.eu'));
refuses('remove: not an address', fn () => AccountRequest::forRemove('u', 'x'));

// MailServers::fromConfig
$defaults = MailServers::fromConfig(fn (string $k, string $d): string => $d);
check('default imap', ['imap.qboxmail.com', 993, 'ssl'], [$defaults->imapHost, $defaults->imapPort, $defaults->imapSsl]);
check('default smtp', ['smtp.qboxmail.com', 465, 'ssl'], [$defaults->smtpHost, $defaults->smtpPort, $defaults->smtpSsl]);
$custom = MailServers::fromConfig(fn (string $k, string $d): string => ['smtp_port' => '587', 'smtp_ssl' => 'tls', 'imap_host' => ' IMAP.Example.EU '][$k] ?? $d);
check('configured values win, host lower-cased', ['imap.example.eu', 587, 'tls'], [$custom->imapHost, $custom->smtpPort, $custom->smtpSsl]);
check('an empty value means the default', 'imap.qboxmail.com', MailServers::fromConfig(fn (string $k, string $d): string => $k === 'imap_host' ? '' : $d)->imapHost);
refuses('host with a slash', fn () => MailServers::fromConfig(fn (string $k, string $d): string => $k === 'imap_host' ? 'evil.example/x' : $d));
refuses('port not a number', fn () => MailServers::fromConfig(fn (string $k, string $d): string => $k === 'imap_port' ? '99x' : $d));
refuses('port out of range', fn () => MailServers::fromConfig(fn (string $k, string $d): string => $k === 'smtp_port' ? '70000' : $d));
refuses('unknown ssl mode', fn () => MailServers::fromConfig(fn (string $k, string $d): string => $k === 'smtp_ssl' ? 'starttls' : $d));

// Against a Nextcloud tree: the methods the app calls, by reflection on the real classes.
if (isset($argv[1])) {
	$root = rtrim($argv[1], '/');
	require_once $root . '/lib/base.php';
	\OC_App::loadApp('mail');
	$m = static fn (string $class, string $method): ?ReflectionMethod => method_exists($class, $method) ? new ReflectionMethod($class, $method) : null;
	$params = static fn (?ReflectionMethod $r): array => $r ? array_map(static fn ($p) => $p->getName(), $r->getParameters()) : [];
	check('SetupService::createNewAccount parameters', [
		'accountName', 'emailAddress', 'imapHost', 'imapPort', 'imapSslMode', 'imapUser', 'imapPassword',
		'smtpHost', 'smtpPort', 'smtpSslMode', 'smtpUser', 'smtpPassword', 'uid', 'authMethod', 'accountId', 'classificationEnabled',
	], $params($m(\OCA\Mail\Service\SetupService::class, 'createNewAccount')));
	check('AccountService::findByUserIdAndAddress', ['userId', 'address'], $params($m(\OCA\Mail\Service\AccountService::class, 'findByUserIdAndAddress')));
	check('AccountService::update', ['account'], $params($m(\OCA\Mail\Service\AccountService::class, 'update')));
	check('AccountService::delete', ['currentUserId', 'accountId'], $params($m(\OCA\Mail\Service\AccountService::class, 'delete')));
	check('Account::getMailAccount', true, method_exists(\OCA\Mail\Account::class, 'getMailAccount'));
	$props = array_map(static fn ($p) => $p->getName(), (new ReflectionClass(\OCA\Mail\Db\MailAccount::class))->getProperties());
	foreach (['inboundHost', 'inboundPort', 'inboundSslMode', 'inboundUser', 'inboundPassword', 'outboundHost', 'outboundPort', 'outboundSslMode', 'outboundUser', 'outboundPassword', 'authMethod'] as $p) {
		check("MailAccount has {$p}", true, in_array($p, $props, true));
	}
	check('IAppConfig::getValueString', true, method_exists(\OCP\IAppConfig::class, 'getValueString'));
	check('IAppManager::loadApp', true, method_exists(\OCP\App\IAppManager::class, 'loadApp'));
	check('ApiRoute attribute', true, class_exists(\OCP\AppFramework\Http\Attribute\ApiRoute::class));
}

echo "{$count} checks, {$failures} failed\n";
exit($failures === 0 ? 0 : 1);

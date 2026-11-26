<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Dunetrails
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Unit tests for the pure parts of the app; no Nextcloud needed:
 *   php tests/run.php
 * With a Nextcloud tree next to it (e.g. inside the image), the share XML is also read back
 * through Sabre and OCA\DAV\DAV\Sharing\Xml\ShareRequest:
 *   php tests/run.php /var/www/html
 * The behaviour against a live instance is covered by scripts/audit-app-isolation.ps1.
 */

require __DIR__ . '/../lib/Service/Rule.php';

use OCA\GantaraIsolation\Service\Rule;

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

// shareAGroup
check('common group', true, Rule::shareAGroup(['a', 'fam'], ['b', 'fam'], []));
check('no common group', false, Rule::shareAGroup(['a'], ['b'], []));
check('only excluded group in common', false, Rule::shareAGroup(['a', 'all'], ['b', 'all'], ['all']));
check('excluded plus a real one', true, Rule::shareAGroup(['a', 'all', 'fam'], ['b', 'all', 'fam'], ['all']));
check('no groups at all', false, Rule::shareAGroup([], [], []));

// normalizePath
check('collapse slashes', 'files/b/x', Rule::normalizePath('/files//b///x/'));
check('dot segments', 'files/b', Rule::normalizePath('files/a/../b/.'));
check('dotdot above root', 'b', Rule::normalizePath('../../b'));

$collections = [
	'principals/users' => Rule::KIND_USER,
	'principals/groups' => Rule::KIND_GROUP,
	'calendars' => Rule::KIND_USER,
	'addressbooks/users' => Rule::KIND_USER,
	'files' => Rule::KIND_USER,
];
check('principal', [Rule::KIND_USER, 'bob'], Rule::principalOf('principals/users/bob', $collections));
check('proxy child', [Rule::KIND_USER, 'bob'], Rule::principalOf('principals/users/bob/calendar-proxy-write', $collections));
check('calendar home', [Rule::KIND_USER, 'bob'], Rule::principalOf('calendars/bob/personal/x.ics', $collections));
check('address book home', [Rule::KIND_USER, 'bob'], Rule::principalOf('addressbooks/users/bob/contacts', $collections));
check('group', [Rule::KIND_GROUP, 'fam ily'], Rule::principalOf('principals/groups/fam ily', $collections));
check('double slash', [Rule::KIND_USER, 'bob'], Rule::principalOf('files//bob/a', $collections));
check('dotdot into another home', [Rule::KIND_USER, 'bob'], Rule::principalOf('files/me/../bob', $collections));
check('collection itself', null, Rule::principalOf('principals/users', $collections));
check('collection with slash', null, Rule::principalOf('calendars/', $collections));
check('root', null, Rule::principalOf('', $collections));
check('system address book', null, Rule::principalOf('addressbooks/system/system/system', $collections));
check('other root', null, Rule::principalOf('public-calendars/abc', $collections));
check('principals root', null, Rule::principalOf('principals/system/system', $collections));

// shareRequestXml
$xml = Rule::shareRequestXml(
	[
		['href' => 'principal:principals/users/c', 'commonName' => 'C & <c>', 'summary' => null, 'readOnly' => false],
		['href' => 'mailto:d@example.org', 'commonName' => null, 'summary' => 's', 'readOnly' => true],
	],
	['principal:principals/users/b'],
);
$dom = new DOMDocument();
check('xml parses', true, $dom->loadXML($xml));
check('xml root', 'share', $dom->documentElement->localName);
check('xml root ns', 'http://owncloud.org/ns', $dom->documentElement->namespaceURI);
check('xml escapes', 'C & <c>', $dom->getElementsByTagNameNS('http://owncloud.org/ns', 'common-name')->item(0)->textContent);
check('xml read-write once', 1, $dom->getElementsByTagNameNS('http://owncloud.org/ns', 'read-write')->length);
check('xml removes', 1, $dom->getElementsByTagNameNS('http://owncloud.org/ns', 'remove')->length);
check('empty share', true, (new DOMDocument())->loadXML(Rule::shareRequestXml([], [])));

$root = $argv[1] ?? null;
if ($root !== null) {
	require $root . '/3rdparty/autoload.php';
	require $root . '/apps/dav/lib/DAV/Sharing/Plugin.php';
	require $root . '/apps/dav/lib/DAV/Sharing/Xml/ShareRequest.php';
	$service = new Sabre\Xml\Service();
	$service->elementMap['{http://owncloud.org/ns}share'] = OCA\DAV\DAV\Sharing\Xml\ShareRequest::class;
	$parsed = $service->parse($xml, null, $rootName);
	check('sabre root', '{http://owncloud.org/ns}share', $rootName);
	check('sabre set', [
		['href' => 'principal:principals/users/c', 'commonName' => 'C & <c>', 'summary' => null, 'readOnly' => false],
		['href' => 'mailto:d@example.org', 'commonName' => null, 'summary' => 's', 'readOnly' => true],
	], $parsed->set);
	check('sabre remove', ['principal:principals/users/b'], $parsed->remove);
}

echo "{$count} checks, {$failures} failed\n";
exit($failures === 0 ? 0 : 1);

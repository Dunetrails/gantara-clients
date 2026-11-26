<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Dunetrails
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\GantaraIsolation\Service;

/**
 * Pure helpers, free of Nextcloud and Sabre types so tests/run.php can load them on plain PHP.
 */
final class Rule {
	public const KIND_USER = 'user';
	public const KIND_GROUP = 'group';

	/**
	 * Core's RestrictInteractionListener rule for Files shares: the two accounts share a group
	 * that is not on the exclusion list.
	 *
	 * @param string[] $mine
	 * @param string[] $theirs
	 * @param string[] $excluded
	 */
	public static function shareAGroup(array $mine, array $theirs, array $excluded): bool {
		return array_diff(array_intersect($mine, $theirs), $excluded) !== [];
	}

	/**
	 * Collapses repeated slashes and resolves "." and "..", the way Sabre's tree ends up walking
	 * the path.
	 */
	public static function normalizePath(string $path): string {
		$out = [];
		foreach (explode('/', $path) as $part) {
			if ($part === '' || $part === '.') {
				continue;
			}
			if ($part === '..') {
				array_pop($out);
				continue;
			}
			$out[] = $part;
		}
		return implode('/', $out);
	}

	/**
	 * Finds the principal a DAV path belongs to.
	 *
	 * @param array<string, string> $collections collection path (e.g. "calendars",
	 *                                           "addressbooks/users") => KIND_*
	 * @return array{0: string, 1: string}|null [kind, principal name] or null when the path is
	 *                                          not below a principal collection
	 */
	public static function principalOf(string $path, array $collections): ?array {
		$parts = explode('/', self::normalizePath($path));
		for ($depth = 2; $depth >= 1; $depth--) {
			if (count($parts) <= $depth) {
				continue;
			}
			$prefix = implode('/', array_slice($parts, 0, $depth));
			if (isset($collections[$prefix])) {
				return [$collections[$prefix], $parts[$depth]];
			}
		}
		return null;
	}

	/**
	 * Body for an oc:share POST, as OCA\DAV\DAV\Sharing\Xml\ShareRequest reads it back.
	 *
	 * @param list<array{href: string, commonName?: ?string, summary?: ?string, readOnly?: bool}> $set
	 * @param list<string> $remove
	 */
	public static function shareRequestXml(array $set, array $remove): string {
		$e = static fn (string $s): string => htmlspecialchars($s, ENT_XML1 | ENT_QUOTES, 'UTF-8');
		$xml = '<?xml version="1.0" encoding="utf-8"?>' . "\n"
			. '<o:share xmlns:d="DAV:" xmlns:o="http://owncloud.org/ns">';
		foreach ($set as $sharee) {
			$xml .= '<o:set><d:href>' . $e($sharee['href']) . '</d:href>';
			if (($sharee['commonName'] ?? null) !== null) {
				$xml .= '<o:common-name>' . $e((string)$sharee['commonName']) . '</o:common-name>';
			}
			if (($sharee['summary'] ?? null) !== null) {
				$xml .= '<o:summary>' . $e((string)$sharee['summary']) . '</o:summary>';
			}
			if (($sharee['readOnly'] ?? true) === false) {
				$xml .= '<o:read-write/>';
			}
			$xml .= '</o:set>';
		}
		foreach ($remove as $href) {
			$xml .= '<o:remove><d:href>' . $e($href) . '</d:href></o:remove>';
		}
		return $xml . '</o:share>';
	}
}

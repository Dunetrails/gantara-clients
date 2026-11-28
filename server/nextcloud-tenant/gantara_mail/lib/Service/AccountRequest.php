<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Dunetrails
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\GantaraMail\Service;

use InvalidArgumentException;

/**
 * What the portal asks for, checked. Pure: no Nextcloud classes, so tests/run.php covers it.
 */
final class AccountRequest {
	public const MAX_PASSWORD = 1024;

	private function __construct(
		public readonly string $uid,
		public readonly string $email,
		public readonly string $name,
		public readonly string $password,
	) {
	}

	/** @throws InvalidArgumentException */
	public static function forUpsert(string $uid, string $email, string $name, string $password): self {
		$uid = self::uid($uid);
		$email = self::email($email);
		if ($password === '' || strlen($password) > self::MAX_PASSWORD) {
			throw new InvalidArgumentException('password must be 1 to ' . self::MAX_PASSWORD . ' bytes');
		}
		$name = trim(preg_replace('/[\x00-\x1f\x7f]+/', ' ', $name) ?? '');
		if ($name === '') {
			$name = $email;
		}
		return new self($uid, $email, mb_substr($name, 0, 255), $password);
	}

	/** @throws InvalidArgumentException */
	public static function forRemove(string $uid, string $email): self {
		return new self(self::uid($uid), self::email($email), '', '');
	}

	private static function uid(string $uid): string {
		$uid = trim($uid);
		if ($uid === '' || strlen($uid) > 64) {
			throw new InvalidArgumentException('uid must be 1 to 64 characters');
		}
		return $uid;
	}

	private static function email(string $email): string {
		$email = strtolower(trim($email));
		if (strlen($email) > 254 || filter_var($email, FILTER_VALIDATE_EMAIL) === false) {
			throw new InvalidArgumentException('email is not a mail address');
		}
		return $email;
	}
}

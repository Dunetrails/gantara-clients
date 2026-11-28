<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Dunetrails
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\GantaraMail\Service;

use InvalidArgumentException;

/**
 * The Gantara Mail (Qboxmail) servers every account gets. Read from this app's config
 * (`occ config:app:set gantara_mail imap_host --value ...`), never from the request, so the API
 * cannot point anyone's Mail at another server. Pure: covered by tests/run.php.
 */
final class MailServers {
	public const DEFAULTS = [
		'imap_host' => 'imap.qboxmail.com',
		'imap_port' => '993',
		'imap_ssl' => 'ssl',
		'smtp_host' => 'smtp.qboxmail.com',
		'smtp_port' => '465',
		'smtp_ssl' => 'ssl',
	];
	/** Mail's values: implicit TLS, STARTTLS, none. */
	private const SSL_MODES = ['ssl', 'tls', 'none'];

	private function __construct(
		public readonly string $imapHost,
		public readonly int $imapPort,
		public readonly string $imapSsl,
		public readonly string $smtpHost,
		public readonly int $smtpPort,
		public readonly string $smtpSsl,
	) {
	}

	/**
	 * @param callable(string $key, string $default): string $get
	 * @throws InvalidArgumentException on a broken config value
	 */
	public static function fromConfig(callable $get): self {
		$v = [];
		foreach (self::DEFAULTS as $key => $default) {
			$value = trim($get($key, $default));
			$v[$key] = $value === '' ? $default : $value;
		}
		foreach (['imap', 'smtp'] as $p) {
			if (!preg_match('/^[a-z0-9.-]+$/i', $v["{$p}_host"])) {
				throw new InvalidArgumentException("{$p}_host is not a host name");
			}
			if (!ctype_digit($v["{$p}_port"]) || (int)$v["{$p}_port"] < 1 || (int)$v["{$p}_port"] > 65535) {
				throw new InvalidArgumentException("{$p}_port is not a port");
			}
			if (!in_array($v["{$p}_ssl"], self::SSL_MODES, true)) {
				throw new InvalidArgumentException("{$p}_ssl must be ssl, tls or none");
			}
		}
		return new self(
			strtolower($v['imap_host']), (int)$v['imap_port'], $v['imap_ssl'],
			strtolower($v['smtp_host']), (int)$v['smtp_port'], $v['smtp_ssl'],
		);
	}
}

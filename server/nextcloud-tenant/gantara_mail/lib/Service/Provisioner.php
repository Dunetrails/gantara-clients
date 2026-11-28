<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Dunetrails
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\GantaraMail\Service;

use OCA\GantaraMail\AppInfo\Application;
use OCA\Mail\Db\MailAccount;
use OCA\Mail\Service\AccountService;
use OCA\Mail\Service\SetupService;
use OCP\App\IAppManager;
use OCP\IAppConfig;
use OCP\IUserManager;
use OCP\Security\ICrypto;
use Psr\Container\ContainerInterface;
use Psr\Log\LoggerInterface;
use RuntimeException;

/**
 * Creates, updates and removes a user's Gantara Mail account in Nextcloud Mail, through Mail's own
 * SetupService and AccountService, exactly as the Mail UI does. Mail's classes are only resolved
 * after loadApp('mail'): the app is enabled per group, and this runs as the portal's admin.
 */
class Provisioner {
	public function __construct(
		private IUserManager $users,
		private IAppManager $apps,
		private IAppConfig $config,
		private ICrypto $crypto,
		private ContainerInterface $container,
		private LoggerInterface $logger,
	) {
	}

	/**
	 * Adds the mailbox to the user's Mail, or sets the new password (and our servers) on the
	 * account they already have for that address. No connection test: Qboxmail can take a few
	 * seconds to accept a password it was just given, and the portal has already set it there.
	 *
	 * @return array{id: int, created: bool}
	 * @throws UnknownUserException
	 */
	public function upsert(AccountRequest $r): array {
		if (!$this->users->userExists($r->uid)) {
			throw new UnknownUserException($r->uid);
		}
		$servers = $this->servers();
		[$setup, $accounts] = $this->mail();

		$existing = $accounts->findByUserIdAndAddress($r->uid, $r->email);
		$created = $existing === [];
		if ($created) {
			// Null passwords: SetupService then skips its connectivity test. They are set below.
			$account = $setup->createNewAccount(
				$r->name, $r->email,
				$servers->imapHost, $servers->imapPort, $servers->imapSsl, $r->email, null,
				$servers->smtpHost, $servers->smtpPort, $servers->smtpSsl, $r->email, null,
				$r->uid, 'password',
			);
			$mailAccount = $account->getMailAccount();
		} else {
			$mailAccount = $existing[0]->getMailAccount();
		}

		$this->applyServers($mailAccount, $servers, $r->email);
		$mailAccount->setAuthMethod('password');
		$mailAccount->setInboundPassword($this->crypto->encrypt($r->password));
		$mailAccount->setOutboundPassword($this->crypto->encrypt($r->password));
		$accounts->update($mailAccount);

		$this->logger->info('Gantara Mail account {action} in Nextcloud Mail', [
			'app' => Application::APP_ID, 'action' => $created ? 'created' : 'updated', 'uid' => $r->uid, 'accountId' => $mailAccount->getId(),
		]);
		return ['id' => (int)$mailAccount->getId(), 'created' => $created];
	}

	/**
	 * Removes every Mail account the user has for the address. An unknown user or no such account
	 * is not an error: the portal retries removals until they report success.
	 *
	 * @return array{deleted: int}
	 */
	public function remove(AccountRequest $r): array {
		if (!$this->users->userExists($r->uid)) {
			return ['deleted' => 0];
		}
		[, $accounts] = $this->mail();
		$n = 0;
		foreach ($accounts->findByUserIdAndAddress($r->uid, $r->email) as $account) {
			$accounts->delete($r->uid, $account->getId());
			$n++;
		}
		if ($n > 0) {
			$this->logger->info('Gantara Mail account removed from Nextcloud Mail', ['app' => Application::APP_ID, 'uid' => $r->uid, 'count' => $n]);
		}
		return ['deleted' => $n];
	}

	private function applyServers(MailAccount $a, MailServers $s, string $email): void {
		$a->setInboundHost($s->imapHost);
		$a->setInboundPort($s->imapPort);
		$a->setInboundSslMode($s->imapSsl);
		$a->setInboundUser($email);
		$a->setOutboundHost($s->smtpHost);
		$a->setOutboundPort($s->smtpPort);
		$a->setOutboundSslMode($s->smtpSsl);
		$a->setOutboundUser($email);
	}

	private function servers(): MailServers {
		return MailServers::fromConfig(fn (string $key, string $default): string => $this->config->getValueString(Application::APP_ID, $key, $default));
	}

	/** @return array{0: SetupService, 1: AccountService} */
	private function mail(): array {
		if (!$this->apps->isInstalled('mail')) {
			throw new RuntimeException('the Mail app is not installed');
		}
		$this->apps->loadApp('mail');
		return [$this->container->get(SetupService::class), $this->container->get(AccountService::class)];
	}
}

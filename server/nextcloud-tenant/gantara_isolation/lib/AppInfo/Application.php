<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Dunetrails
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\GantaraIsolation\AppInfo;

use OCA\DAV\Events\SabrePluginAddEvent;
use OCA\GantaraIsolation\Listener\DeckAclCreatedListener;
use OCA\GantaraIsolation\Listener\SabrePluginAddListener;
use OCA\GantaraIsolation\Middleware\DeckMiddleware;
use OCA\GantaraIsolation\Middleware\ProvisioningMiddleware;
use OCP\AppFramework\App;
use OCP\AppFramework\Bootstrap\IBootContext;
use OCP\AppFramework\Bootstrap\IBootstrap;
use OCP\AppFramework\Bootstrap\IRegistrationContext;

class Application extends App implements IBootstrap {
	public const APP_ID = 'gantara_isolation';

	public function __construct() {
		parent::__construct(self::APP_ID);
	}

	#[\Override]
	public function register(IRegistrationContext $context): void {
		$context->registerEventListener(SabrePluginAddEvent::class, SabrePluginAddListener::class);
		// Global: they apply to other apps' controllers (Deck's, provisioning_api's).
		$context->registerMiddleware(DeckMiddleware::class, true);
		$context->registerMiddleware(ProvisioningMiddleware::class, true);
		$context->registerEventListener(DeckAclCreatedListener::EVENT, DeckAclCreatedListener::class);
	}

	#[\Override]
	public function boot(IBootContext $context): void {
	}
}

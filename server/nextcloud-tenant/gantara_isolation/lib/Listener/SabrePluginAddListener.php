<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Dunetrails
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\GantaraIsolation\Listener;

use OCA\DAV\Events\SabrePluginAddEvent;
use OCA\GantaraIsolation\Dav\IsolationPlugin;
use OCP\EventDispatcher\Event;
use OCP\EventDispatcher\IEventListener;
use Psr\Container\ContainerInterface;

/**
 * Only /remote.php/dav dispatches this event. The legacy /remote.php/caldav, /calendar,
 * /carddav and /contacts endpoints build their own server without it, so nginx blocks them
 * on the tenants that enable this app (bootstrap/argocd/applicationset-customers.yaml).
 *
 * @template-implements IEventListener<SabrePluginAddEvent>
 */
class SabrePluginAddListener implements IEventListener {
	public function __construct(
		private ContainerInterface $container,
	) {
	}

	#[\Override]
	public function handle(Event $event): void {
		if (!$event instanceof SabrePluginAddEvent) {
			return;
		}
		$event->getServer()->addPlugin($this->container->get(IsolationPlugin::class));
	}
}

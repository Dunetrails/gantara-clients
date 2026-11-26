<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Dunetrails
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\GantaraIsolation\Listener;

use OCA\GantaraIsolation\Service\Policy;
use OCP\EventDispatcher\Event;
use OCP\EventDispatcher\IEventListener;
use Psr\Container\ContainerInterface;
use Psr\Log\LoggerInterface;

/**
 * Backstop behind DeckMiddleware for a Deck entry point it does not know about: deletes a board
 * share the signed-in user may not give. Deck dispatches AclCreatedEvent after it has stored the
 * share, recorded the activity and sent the "board shared with you" notification, so the
 * recipient may already have been notified; the share itself does not survive. A warning names
 * the board so the entry point can be added to the middleware.
 *
 * @template-implements IEventListener<Event>
 */
class DeckAclCreatedListener implements IEventListener {
	public const EVENT = 'OCA\\Deck\\Event\\AclCreatedEvent';

	public function __construct(
		private ContainerInterface $container,
		private LoggerInterface $logger,
	) {
	}

	#[\Override]
	public function handle(Event $event): void {
		if (!is_a($event, self::EVENT)) {
			return;
		}
		$policy = $this->container->get(Policy::class);
		/** @var \OCA\Deck\Db\Acl $acl */
		$acl = $event->getAcl();
		if (!$policy->isActive() || $policy->canShareDeck((int)$acl->getType(), (string)$acl->getParticipant())) {
			return;
		}
		try {
			$this->container->get('OCA\\Deck\\Db\\AclMapper')->delete($acl);
			$this->logger->warning('Deleted a Deck share outside the user\'s groups (board ' . $acl->getBoardId() . ', type ' . $acl->getType() . '); an entry point is missing from DeckMiddleware', ['app' => 'gantara_isolation']);
		} catch (\Throwable $e) {
			$this->logger->error('Could not delete a Deck share outside the user\'s groups (board ' . $acl->getBoardId() . ')', ['app' => 'gantara_isolation', 'exception' => $e]);
		}
	}
}

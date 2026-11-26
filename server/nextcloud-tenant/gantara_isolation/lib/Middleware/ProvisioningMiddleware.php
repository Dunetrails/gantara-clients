<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Dunetrails
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\GantaraIsolation\Middleware;

use OCA\GantaraIsolation\Service\Policy;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Middleware;
use OCP\AppFramework\OCS\OCSException;
use OCP\AppFramework\OCSController;
use OCP\IGroupManager;
use OCP\IRequest;
use Psr\Container\ContainerInterface;

/**
 * GET /cloud/users/{userId} answers a plain user 998 for an existing account they may not read
 * and 404 "User does not exist" for an unknown uid. While the rule applies, every uid other than
 * their own gets the 998 answer before the controller looks the account up. Admins, delegated
 * admins and sub-admins keep core's behaviour.
 */
class ProvisioningMiddleware extends Middleware {
	private const CONTROLLER = 'OCA\\Provisioning_API\\Controller\\UsersController';

	public function __construct(
		private ContainerInterface $container,
		private IRequest $request,
	) {
	}

	#[\Override]
	public function beforeController(Controller $controller, string $methodName): void {
		if (get_class($controller) !== self::CONTROLLER || strtolower($methodName) !== 'getuser') {
			return;
		}
		$policy = $this->container->get(Policy::class);
		$me = $policy->subject();
		if ($me === null || $this->request->getParam('userId') === $me->getUID()) {
			return;
		}
		$groupManager = $this->container->get(IGroupManager::class);
		if ($groupManager->isAdmin($me->getUID())
			|| $groupManager->isDelegatedAdmin($me->getUID())
			|| $groupManager->getSubAdmin()->isSubAdmin($me)) {
			return;
		}
		throw new OCSException('', OCSController::RESPOND_NOT_FOUND);
	}
}

<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Dunetrails
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\GantaraIsolation\Middleware;

use OCA\GantaraIsolation\Service\Policy;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Db\DoesNotExistException;
use OCP\AppFramework\Db\MultipleObjectsReturnedException;
use OCP\AppFramework\Http;
use OCP\AppFramework\Http\JSONResponse;
use OCP\AppFramework\Http\Response;
use OCP\AppFramework\Middleware;
use OCP\AppFramework\OCSController;
use OCP\IRequest;
use Psr\Container\ContainerInterface;
use Psr\Log\LoggerInterface;

/**
 * Registered for every app's controllers; acts on Deck's only. Deck never consults
 * shareapi_only_share_with_group_members, so while the rule applies:
 *
 *  - addAcl (web, REST API, OCS) refuses a user or group the user may not share with. An unknown
 *    uid or gid is refused the same way: 400 "Sharing is only allowed with group members.".
 *  - transferOwner refuses a new owner the user may not share with, with the same answer.
 *  - clone of a readable board is refused when it would copy an ACL the user may not give.
 *  - import (web upload and REST API) is refused for everyone but admins. Its user mapping,
 *    member list, ACLs and comment authors would each need checking, and an import that fails
 *    on unknown accounts only is itself an oracle.
 *
 * Middlewares registered by apps run in app registration order, so Deck's ExceptionMiddleware
 * sees exceptions after this one. Web and REST refusals get Deck's JSON answer here. OCS
 * refusals are rethrown for Deck's ExceptionMiddleware to turn into an OCSException; were the
 * order ever reversed they would surface as a 500, still refused.
 */
class DeckMiddleware extends Middleware {
	private const DECK = 'OCA\\Deck\\Controller\\';
	private const SHARING = 'Sharing is only allowed with group members.';
	private const IMPORT = 'Importing boards is not available on this instance.';
	private const ACL_CONTROLLERS = ['BoardController', 'BoardApiController', 'BoardOcsController'];
	private const CLONE_CONTROLLERS = ['BoardController', 'BoardApiController'];
	private const IMPORT_CONTROLLERS = ['BoardController', 'BoardImportApiController'];

	private ?\Exception $refusal = null;

	public function __construct(
		private ContainerInterface $container,
		private IRequest $request,
		private LoggerInterface $logger,
	) {
	}

	#[\Override]
	public function beforeController(Controller $controller, string $methodName): void {
		$class = get_class($controller);
		if (!str_starts_with($class, self::DECK)) {
			return;
		}
		$policy = $this->container->get(Policy::class);
		if (!$policy->isActive()) {
			return;
		}
		$name = substr($class, strlen(self::DECK));
		$method = strtolower($methodName);

		if ($method === 'addacl' && in_array($name, self::ACL_CONTROLLERS, true)) {
			$type = $this->request->getParam('type');
			$participant = $this->request->getParam('participant');
			if (!is_numeric($type) || !is_scalar($participant)
				|| !$policy->canShareDeck((int)$type, (string)$participant)) {
				$this->refuse(self::SHARING);
			}
		} elseif ($method === 'transferowner' && $name === 'BoardController') {
			$newOwner = $this->request->getParam('newOwner');
			if (!is_scalar($newOwner) || !$policy->canShareDeck(Policy::DECK_USER, (string)$newOwner)) {
				$this->refuse(self::SHARING);
			}
		} elseif ($method === 'clone' && in_array($name, self::CLONE_CONTROLLERS, true)) {
			$this->checkClone($policy, $this->request->getParam('boardId'));
		} elseif ($method === 'import' && in_array($name, self::IMPORT_CONTROLLERS, true)) {
			if (!$policy->isAdmin()) {
				$this->refuse(self::IMPORT);
			}
		}
	}

	#[\Override]
	public function afterException($controller, $methodName, \Exception $exception): Response {
		if ($this->refusal === null || $exception !== $this->refusal || $controller instanceof OCSController) {
			throw $exception;
		}
		return new JSONResponse(['status' => Http::STATUS_BAD_REQUEST, 'message' => $exception->getMessage()], Http::STATUS_BAD_REQUEST);
	}

	private function checkClone(Policy $policy, mixed $boardId): void {
		if (!is_numeric($boardId)) {
			return;
		}
		try {
			/** @var \OCA\Deck\Service\PermissionService $permissions */
			$permissions = $this->container->get('OCA\\Deck\\Service\\PermissionService');
			$read = $permissions->getPermissions((int)$boardId)[0] ?? false;
		} catch (DoesNotExistException|MultipleObjectsReturnedException) {
			return;
		} catch (\Throwable $e) {
			if (is_a($e, 'OCA\\Deck\\NoPermissionException')) {
				return;
			}
			$this->logger->error('Could not check a Deck clone; refusing it', ['app' => 'gantara_isolation', 'exception' => $e]);
			$this->refuse(self::SHARING);
		}
		if (!$read) {
			// Deck refuses it itself.
			return;
		}
		try {
			/** @var \OCA\Deck\Db\AclMapper $aclMapper */
			$aclMapper = $this->container->get('OCA\\Deck\\Db\\AclMapper');
			$acls = $aclMapper->findAll((int)$boardId);
		} catch (\Throwable $e) {
			$this->logger->error('Could not read a Deck board\'s sharing; refusing the clone', ['app' => 'gantara_isolation', 'exception' => $e]);
			$this->refuse(self::SHARING);
		}
		foreach ($acls as $acl) {
			if (!$policy->canShareDeck((int)$acl->getType(), (string)$acl->getParticipant())) {
				$this->refuse(self::SHARING);
			}
		}
	}

	private function refuse(string $message): never {
		$class = 'OCA\\Deck\\BadRequestException';
		$this->refusal = class_exists($class) ? new $class($message) : new \InvalidArgumentException($message);
		throw $this->refusal;
	}
}

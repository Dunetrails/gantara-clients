<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Dunetrails
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\GantaraIsolation\Dav;

use OCA\DAV\DAV\Sharing\IShareable;
use OCA\DAV\DAV\Sharing\Xml\ShareRequest;
use OCA\GantaraIsolation\Service\Policy;
use OCA\GantaraIsolation\Service\Rule;
use OCP\IUserManager;
use Psr\Log\LoggerInterface;
use Sabre\DAV\Exception;
use Sabre\DAV\Exception\Conflict;
use Sabre\DAV\Exception\Forbidden;
use Sabre\DAV\Exception\NotFound;
use Sabre\DAV\INode;
use Sabre\DAV\PropFind;
use Sabre\DAV\PropPatch;
use Sabre\DAV\Server;
use Sabre\DAV\ServerPlugin;
use Sabre\DAV\SimpleCollection;
use Sabre\DAV\Xml\Property\Href;
use Sabre\DAVACL\AbstractPrincipalCollection;
use Sabre\HTTP\RequestInterface;
use Sabre\HTTP\ResponseInterface;

/**
 * Applies the Files sharing rule to the DAV tree (/remote.php/dav):
 *
 *  - Requests below another account's principal, calendar home, address book home, files,
 *    uploads, avatars (any collection keyed by principals/users) answer 404 "Principal with name
 *    <x> not found", which is what Sabre answers for an unknown uid, unless the two share a
 *    group outside the exclusion list. Unknown accounts take the same path, so the answer and
 *    the work done are the same for both. principals/groups/<gid> needs membership.
 *  - The same paths are left out of multi-path results (expand-property, multiget, searches).
 *  - oc:share POSTs (calendar and address book sharing) lose every <set> whose href the user
 *    may not share with; core skips those exactly as it skips an unknown principal. When none
 *    is left the plugin gives core's answer itself. <remove> is untouched, so an owner can
 *    always revoke.
 *  - Calendar delegation (calendar-proxy-* group-member-set) fails like an unknown principal.
 *  - The ACL method is refused (Sabre's ACL plugin would report which principals exist).
 *
 * Nothing happens when shareapi_only_share_with_group_members is off or nobody is signed in.
 */
class IsolationPlugin extends ServerPlugin {
	private const NS_OWNCLOUD = 'http://owncloud.org/ns';
	private const PROXY_NODES = ['calendar-proxy-read', 'calendar-proxy-write'];
	private ?Server $server = null;
	/** @var array<string, string>|null */
	private ?array $collections = null;
	private int $rootChildren = -1;

	public function __construct(
		private Policy $policy,
		private IUserManager $userManager,
		private LoggerInterface $logger,
	) {
	}

	#[\Override]
	public function getPluginName(): string {
		return 'gantara-isolation';
	}

	#[\Override]
	public function initialize(Server $server): void {
		$this->server = $server;
		// After authentication (10) and before the ACL plugin (20), which would answer 403 for
		// an existing home instead of 404.
		$server->on('beforeMethod:*', [$this, 'checkRequest'], 15);
		// App collections (trashbin, versions, ...) are added to the tree at priority 100.
		$server->on('beforeMethod:*', [$this, 'checkRequestAgain'], 101);
		$server->on('propFind', [$this, 'propFindEarly'], 1);
		$server->on('propFind', [$this, 'propFindLate'], 500);
		$server->on('propPatch', [$this, 'propPatch'], 1);
		// Before OCA\DAV\DAV\Sharing\Plugin::httpPost (100).
		$server->on('method:POST', [$this, 'httpPost'], 10);
		$server->on('method:ACL', [$this, 'httpAcl'], 10);
	}

	public function checkRequest(RequestInterface $request, ResponseInterface $response): void {
		if (!$this->policy->isActive()) {
			return;
		}
		$this->assertVisible($request->getPath());
		$method = $request->getMethod();
		if ($method === 'MOVE' || $method === 'COPY') {
			$destination = $request->getHeader('Destination');
			if ($destination === null || $destination === '') {
				return;
			}
			try {
				$path = $this->server->calculateUri($destination);
			} catch (\Throwable) {
				return;
			}
			if (!$this->isVisiblePath($path)) {
				// Sabre's answer when the destination's parent does not exist.
				throw new Conflict('The destination node is not found');
			}
		}
	}

	public function checkRequestAgain(RequestInterface $request, ResponseInterface $response): void {
		if ($this->policy->isActive() && $this->rootChildCount() !== $this->rootChildren) {
			$this->collections = null;
			$this->checkRequest($request, $response);
		}
	}

	/** Leaves another account's resources out of multi-path responses. */
	public function propFindEarly(PropFind $propFind, INode $node): ?bool {
		if (!$this->policy->isActive() || $this->isVisiblePath($propFind->getPath())) {
			return null;
		}
		return false;
	}

	/** A group on the exclusion list shows no members, as core lists no sharees for it. */
	public function propFindLate(PropFind $propFind, INode $node): void {
		if (!$this->policy->isActive()) {
			return;
		}
		$principal = Rule::principalOf($propFind->getPath(), $this->collections());
		if ($principal === null || $principal[0] !== Rule::KIND_GROUP
			|| $propFind->getStatus('{DAV:}group-member-set') !== 200
			|| !$this->policy->isExcludedGroup(urldecode($principal[1]))) {
			return;
		}
		$propFind->set('{DAV:}group-member-set', new Href([]), 200);
	}

	/**
	 * Calendar delegation: an invisible member fails with the exception
	 * PrincipalProxyTrait::setGroupMemberSet throws for an unknown one, in the same order.
	 */
	public function propPatch(string $path, PropPatch $propPatch): void {
		$mutations = $propPatch->getMutations();
		$value = $mutations['{DAV:}group-member-set'] ?? null;
		if (!$value instanceof Href || !$this->policy->isActive()) {
			return;
		}
		$path = Rule::normalizePath($path);
		$parts = explode('/', $path);
		if (count($parts) !== 4 || $parts[0] !== 'principals' || $parts[1] !== 'users'
			|| !in_array($parts[3], self::PROXY_NODES, true)) {
			return;
		}
		foreach ($value->getHrefs() as $href) {
			try {
				$member = $this->server->calculateUri($href);
			} catch (\Throwable) {
				return;
			}
			$memberParts = explode('/', Rule::normalizePath($member));
			if (count($memberParts) !== 3 || $memberParts[0] !== 'principals' || $memberParts[1] !== 'users') {
				return;
			}
			if (!$this->policy->canSeeUid(urldecode($memberParts[2]))) {
				throw new Exception('Principal not found');
			}
		}
	}

	/** Drops share invitations to principals the user may not share with. */
	public function httpPost(RequestInterface $request, ResponseInterface $response): ?bool {
		$contentType = (string)$request->getHeader('Content-Type');
		if ((!str_contains($contentType, 'application/xml') && !str_contains($contentType, 'text/xml'))
			|| !$this->policy->isActive()) {
			return null;
		}
		$body = $request->getBodyAsString();
		$request->setBody($body);
		try {
			$message = $this->server->xml->parse($body, $request->getUrl(), $documentType);
		} catch (\Throwable) {
			return null;
		}
		if ($documentType !== '{' . self::NS_OWNCLOUD . '}share' || !$message instanceof ShareRequest) {
			return null;
		}
		$kept = array_values(array_filter($message->set, fn (array $sharee): bool => $this->maySetSharee((string)$sharee['href'])));
		if (count($kept) === count($message->set)) {
			return null;
		}
		$this->logger->info('Dropped ' . (count($message->set) - count($kept)) . ' DAV share invitation(s) outside the user\'s groups', ['app' => 'gantara_isolation']);
		if ($kept === [] && $message->remove === []) {
			// Core refuses an empty share document with 400, so answer as its Sharing plugin does
			// once it has skipped an unknown sharee.
			return $this->answerShareUnchanged($request, $response);
		}
		$request->setBody(Rule::shareRequestXml($kept, array_values($message->remove)));
		return null;
	}

	private function answerShareUnchanged(RequestInterface $request, ResponseInterface $response): ?bool {
		$path = $request->getPath();
		try {
			$node = $this->server->tree->getNodeForPath($path);
		} catch (NotFound) {
			return null;
		}
		if (!$node instanceof IShareable) {
			return null;
		}
		$acl = $this->server->getPlugin('acl');
		if ($acl instanceof \Sabre\DAVACL\Plugin) {
			$acl->checkPrivileges($path, '{DAV:}write-acl');
		}
		$response->setStatus(200);
		$response->setHeader('X-Sabre-Status', 'everything-went-well');
		return false;
	}

	public function httpAcl(RequestInterface $request, ResponseInterface $response): void {
		if ($this->policy->isActive()) {
			throw new Forbidden('Setting ACL is not supported on this node');
		}
	}

	/**
	 * Keeps a share only when core would resolve it to an account or group the user may share
	 * with: principal:principals/users/<uid>, principal:principals/groups/<gid>, or a mailto:
	 * that matches exactly one account (Principal::findByUri). Anything else (Teams, remote
	 * users, unknown schemes) is dropped while the rule applies.
	 */
	private function maySetSharee(string $href): bool {
		if (str_starts_with($href, 'mailto:')) {
			$users = $this->userManager->getByEmail(substr($href, 7));
			return count($users) === 1 && $this->policy->canSeeUser($users[0]);
		}
		if (!str_starts_with($href, 'principal:')) {
			return false;
		}
		$parts = explode('/', Rule::normalizePath(substr($href, 10)));
		if (count($parts) !== 3 || $parts[0] !== 'principals') {
			return false;
		}
		return match ($parts[1]) {
			'users' => $this->policy->canSeeUid(urldecode($parts[2])),
			'groups' => $this->canSeeGroupName($parts[2], true),
			default => false,
		};
	}

	private function assertVisible(string $path): void {
		if (!$this->isVisiblePath($path)) {
			$principal = Rule::principalOf($path, $this->collections());
			throw new NotFound('Principal with name ' . ($principal[1] ?? '') . ' not found');
		}
	}

	private function isVisiblePath(string $path): bool {
		$principal = Rule::principalOf($path, $this->collections());
		if ($principal === null) {
			return true;
		}
		[$kind, $name] = $principal;
		if ($kind === Rule::KIND_GROUP) {
			return $this->canSeeGroupName($name, false);
		}
		$me = $this->policy->subject();
		if ($me !== null && $name === $me->getUID()) {
			return true;
		}
		// Principal::getPrincipalPropertiesByPath decodes the name once more.
		return $this->policy->canSeeUid(urldecode($name));
	}

	/** GroupPrincipalBackend and Principal try the decoded name first, then the raw one. */
	private function canSeeGroupName(string $name, bool $forSharing): bool {
		return $this->policy->canSeeGroup(urldecode($name), $forSharing)
			|| ($name !== urldecode($name) && $this->policy->canSeeGroup($name, $forSharing));
	}

	private function rootChildCount(): int {
		try {
			$root = $this->server->tree->getNodeForPath('');
			return $root instanceof SimpleCollection ? count($root->getChildren()) : 0;
		} catch (\Throwable) {
			return 0;
		}
	}

	/**
	 * Every collection keyed by a user or group principal, read from the tree so app
	 * collections are covered too: path => Rule::KIND_*.
	 *
	 * @return array<string, string>
	 */
	private function collections(): array {
		if ($this->collections !== null) {
			return $this->collections;
		}
		$found = [];
		try {
			$root = $this->server->tree->getNodeForPath('');
			if ($root instanceof SimpleCollection) {
				$children = $root->getChildren();
				$this->rootChildren = count($children);
				foreach ($children as $child) {
					$this->addCollection($found, $child, $child->getName());
					if ($child instanceof SimpleCollection) {
						foreach ($child->getChildren() as $grandChild) {
							$this->addCollection($found, $grandChild, $child->getName() . '/' . $grandChild->getName());
						}
					}
				}
			}
		} catch (\Throwable $e) {
			$this->logger->error('Could not read the DAV tree; using the built-in collection list', ['app' => 'gantara_isolation', 'exception' => $e]);
		}
		if ($found === []) {
			$found = [
				'principals/users' => Rule::KIND_USER,
				'principals/groups' => Rule::KIND_GROUP,
				'calendars' => Rule::KIND_USER,
				'addressbooks/users' => Rule::KIND_USER,
				'files' => Rule::KIND_USER,
				'uploads' => Rule::KIND_USER,
				'avatars' => Rule::KIND_USER,
				'trashbin' => Rule::KIND_USER,
				'versions' => Rule::KIND_USER,
			];
		}
		return $this->collections = $found;
	}

	/** @param array<string, string> $found */
	private function addCollection(array &$found, INode $node, string $path): void {
		if (!$node instanceof AbstractPrincipalCollection) {
			return;
		}
		$prefix = (new \ReflectionProperty(AbstractPrincipalCollection::class, 'principalPrefix'))->getValue($node);
		if ($prefix === 'principals/users') {
			$found[$path] = Rule::KIND_USER;
		} elseif ($prefix === 'principals/groups') {
			$found[$path] = Rule::KIND_GROUP;
		}
	}
}

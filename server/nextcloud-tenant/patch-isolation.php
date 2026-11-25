<?php
// Build-time patches that make the DAV and Deck code honour shareapi_only_share_with_group_members
// the way Files sharing does (docs/plans.md "Contacts and calendar on the shared instance", items 2
// to 4). Run by patch-apps.sh; `php patch-isolation.php <root>` patches a copy elsewhere.
//
// The rule is core's RestrictInteractionListener: another account is visible when the two share a
// group outside shareapi_only_share_with_group_members_exclude_group_list; a group is usable when
// the user is in it and it is not on that list. Unknown and invisible accounts answer the same, so
// there is no existence oracle. Nothing changes when the setting is off (every dedicated tenant) or
// nobody is signed in (occ, cron, public calendar links, invitation replies).
//
// dav (Principal, GroupPrincipalBackend, Sharing\Backend):
//   - principals/users/<uid> and its calendar-proxy-* children: 404 unless visible. That also gates
//     calendar and address-book sharing by `principal:` href (findByUri resolves it through
//     getPrincipalByPath), calendar delegation (setGroupMemberSet) and /calendars/<uid>/ lookups.
//   - findByUri mailto: (invitations, free/busy) takes the exclusion list into account.
//   - principals/groups/<gid>: 404 unless a member; Sabre's ACL walk resolves only the user's own
//     groups. Its member list is empty for excluded groups. Sharing to a group needs membership
//     and a group off the exclusion list.
//   - Removing a share falls back to the raw principal, so an owner can still revoke a share from
//     someone who is no longer visible (left the Family, for example).
// deck (BoardService, BoardImportService, DeckJsonService, TrelloJsonService):
//   - addAcl, clone (skips the ACLs the cloner may not give), transferBoardOwnership, and board
//     import (uidRelation, unmapped members, comment authors, ACLs). Card assignment and comment
//     mentions only reach board members, so they follow from addAcl.
//
// Each replacement must match exactly once, so an upstream change fails the build instead of
// shipping without the patch. Re-check every pattern when Nextcloud or Deck is bumped. dav is a
// shipped app: its integrity check reports the three files as modified (admin overview only).
// Deck's appinfo/signature.json is removed, as for integration_google in patch-apps.sh.

declare(strict_types=1);

$root = rtrim($argv[1] ?? '/usr/src/nextcloud', '/');
$patched = [];

function patch(string $file, string $from, string $to): void {
	global $patched;
	$src = file_get_contents($file);
	if ($src === false) {
		fwrite(STDERR, "patch-isolation: ERROR cannot read {$file}\n");
		exit(1);
	}
	$n = substr_count($src, $from);
	if ($n !== 1) {
		$first = strtok(ltrim($from), "\n");
		fwrite(STDERR, "patch-isolation: ERROR expected 1 match in {$file}, found {$n}: {$first}\n");
		exit(1);
	}
	file_put_contents($file, str_replace($from, $to, $src));
	$patched[$file] = true;
}

// ---------------------------------------------------------------------------------------------
// dav
// ---------------------------------------------------------------------------------------------
$principal = "{$root}/apps/dav/lib/Connector/Sabre/Principal.php";
$groupBackend = "{$root}/apps/dav/lib/DAV/GroupPrincipalBackend.php";
$sharing = "{$root}/apps/dav/lib/DAV/Sharing/Backend.php";

patch($principal, <<<'PHP'
	public function getPrincipalPrefix() {
		return $this->principalPrefix;
	}
PHP, <<<'PHP'
	public function getPrincipalPrefix() {
		return $this->principalPrefix;
	}

	/**
	 * Gantara patch (images/nextcloud-tenant/patch-isolation.php): with
	 * shareapi_only_share_with_group_members, another account is visible only when the two share
	 * a group outside the exclusion list. True when the setting is off or nobody is signed in.
	 */
	public static function gantaraCanSeeUser(IUser $target): bool {
		$shareManager = \OCP\Server::get(IShareManager::class);
		if (!$shareManager->shareWithGroupMembersOnly()) {
			return true;
		}
		$current = \OCP\Server::get(IUserSession::class)->getUser();
		if ($current === null || $current->getUID() === $target->getUID()) {
			return true;
		}
		$groupManager = \OCP\Server::get(IGroupManager::class);
		$common = array_intersect($groupManager->getUserGroupIds($current), $groupManager->getUserGroupIds($target));
		return array_diff($common, $shareManager->shareWithGroupMembersOnlyExcludeGroupsList()) !== [];
	}

	/**
	 * Gantara patch: a group is visible to its members. $forSharing also refuses groups on the
	 * exclusion list, as a group share does; a path lookup must not, because Sabre resolves every
	 * group the user is in when it computes their ACL.
	 */
	public static function gantaraCanSeeGroup(IGroup $group, bool $forSharing): bool {
		$shareManager = \OCP\Server::get(IShareManager::class);
		if (!$shareManager->shareWithGroupMembersOnly()) {
			return true;
		}
		$current = \OCP\Server::get(IUserSession::class)->getUser();
		if ($current === null) {
			return true;
		}
		if (!$group->inGroup($current)) {
			return false;
		}
		return !$forSharing || !in_array($group->getGID(), $shareManager->shareWithGroupMembersOnlyExcludeGroupsList(), true);
	}
PHP);

patch($principal, <<<'PHP'
				$user = $this->userManager->get($name2);

				if ($user !== null) {
PHP, <<<'PHP'
				$user = $this->userManager->get($name2);

				if ($user !== null && self::gantaraCanSeeUser($user)) {
PHP);

patch($principal, <<<'PHP'
			$user = $this->userManager->get($decodedName);

			if ($user !== null) {
PHP, <<<'PHP'
			$user = $this->userManager->get($decodedName);

			if ($user !== null && self::gantaraCanSeeUser($user)) {
PHP);

patch($principal, <<<'PHP'
			if ($group instanceof IGroup) {
				return [
					'uri' => 'principals/groups/' . $name,
PHP, <<<'PHP'
			if ($group instanceof IGroup && self::gantaraCanSeeGroup($group, true)) {
				return [
					'uri' => 'principals/groups/' . $name,
PHP);

patch($principal, <<<'PHP'
				$user = $users[0];

				if ($restrictGroups !== false) {
					$userGroups = $this->groupManager->getUserGroupIds($user);
					if (count(array_intersect($userGroups, $restrictGroups)) === 0) {
						return null;
					}
				}
PHP, <<<'PHP'
				$user = $users[0];

				if ($restrictGroups !== false && !self::gantaraCanSeeUser($user)) {
					return null;
				}
PHP);

patch($groupBackend, <<<'PHP'
		if ($group !== null && !$group->hideFromCollaboration()) {
			return $this->groupToPrincipal($group);
PHP, <<<'PHP'
		if ($group !== null && !$group->hideFromCollaboration()
			&& \OCA\DAV\Connector\Sabre\Principal::gantaraCanSeeGroup($group, false)) {
			return $this->groupToPrincipal($group);
PHP);

patch($groupBackend, <<<'PHP'
		$group = $this->groupManager->get($name);

		if (is_null($group)) {
			return [];
		}
PHP, <<<'PHP'
		$group = $this->groupManager->get($name);

		if (is_null($group) || !\OCA\DAV\Connector\Sabre\Principal::gantaraCanSeeGroup($group, true)) {
			return [];
		}
PHP);

patch($sharing, <<<'PHP'
			$principal = $this->principalBackend->findByUri($element, '')
				?? $this->remoteUserPrincipalBackend->findByUri($element, '');
PHP, <<<'PHP'
			$principal = $this->principalBackend->findByUri($element, '')
				?? $this->remoteUserPrincipalBackend->findByUri($element, '')
				?? (str_starts_with($element, 'principal:principals/')
					&& \OCP\Server::get(\OCP\Share\IManager::class)->shareWithGroupMembersOnly()
					? substr($element, 10) : null);
PHP);

// ---------------------------------------------------------------------------------------------
// deck
// ---------------------------------------------------------------------------------------------
$deck = "{$root}/custom_apps/deck";
if (!is_dir($deck)) {
	echo "patch-isolation: deck not baked, skipping its patches\n";
} else {
	$boardService = "{$deck}/lib/Service/BoardService.php";
	$importService = "{$deck}/lib/Service/Importer/BoardImportService.php";
	$deckJson = "{$deck}/lib/Service/Importer/Systems/DeckJsonService.php";
	$trelloJson = "{$deck}/lib/Service/Importer/Systems/TrelloJsonService.php";
	$refused = "throw new BadRequestException('Sharing is only allowed with group members.');";

	patch($boardService, <<<'PHP'
	/**
	 * Set a different user than the current one, e.g. when no user is available in occ
	 */
PHP, <<<'PHP'
	/**
	 * Gantara patch (images/nextcloud-tenant/patch-isolation.php): with
	 * shareapi_only_share_with_group_members, a board goes only to an account sharing a group
	 * outside the exclusion list, or to a group the user is in and that is not on it. An unknown
	 * account or group is refused the same way. True when the setting is off or nobody is signed in.
	 */
	public static function gantaraCanShareWith(int $type, string $participant): bool {
		$shareManager = Server::get(\OCP\Share\IManager::class);
		if (!$shareManager->shareWithGroupMembersOnly()) {
			return true;
		}
		$current = Server::get(\OCP\IUserSession::class)->getUser();
		if ($current === null) {
			return true;
		}
		$groupManager = Server::get(\OCP\IGroupManager::class);
		$excluded = $shareManager->shareWithGroupMembersOnlyExcludeGroupsList();
		if ($type === Acl::PERMISSION_TYPE_USER) {
			if ($participant === $current->getUID()) {
				return true;
			}
			$target = Server::get(IUserManager::class)->get($participant);
			if ($target === null) {
				return false;
			}
			$common = array_intersect($groupManager->getUserGroupIds($current), $groupManager->getUserGroupIds($target));
			return array_diff($common, $excluded) !== [];
		}
		if ($type === Acl::PERMISSION_TYPE_GROUP) {
			$group = $groupManager->get($participant);
			return $group !== null && $group->inGroup($current) && !in_array($group->getGID(), $excluded, true);
		}
		return true;
	}

	/**
	 * Gantara patch: IUserManager::get() for the board importer, null for an account the user may
	 * not share with (same answer as for an unknown one).
	 */
	public static function gantaraVisibleUser(string $uid): ?\OCP\IUser {
		$user = Server::get(IUserManager::class)->get($uid);
		return $user !== null && self::gantaraCanShareWith(Acl::PERMISSION_TYPE_USER, $user->getUID()) ? $user : null;
	}

	/**
	 * Set a different user than the current one, e.g. when no user is available in occ
	 */
PHP);

	patch($boardService, <<<'PHP'
		$acl = new Acl();
		if ($type === Acl::PERMISSION_TYPE_REMOTE) {
PHP, <<<PHP
		if (!self::gantaraCanShareWith(\$type, (string)\$participant)) {
			{$refused}
		}

		\$acl = new Acl();
		if (\$type === Acl::PERMISSION_TYPE_REMOTE) {
PHP);

	patch($boardService, <<<'PHP'
		foreach ($this->aclMapper->findAll($board->getId()) as $acl) {
			$this->addAcl($newBoard->getId(),
PHP, <<<'PHP'
		foreach ($this->aclMapper->findAll($board->getId()) as $acl) {
			if (!self::gantaraCanShareWith($acl->getType(), (string)$acl->getParticipant())) {
				continue;
			}
			$this->addAcl($newBoard->getId(),
PHP);

	patch($boardService, <<<'PHP'
	public function transferBoardOwnership(int $boardId, string $newOwner, bool $changeContent = false): Board {
		$this->connection->beginTransaction();
PHP, <<<PHP
	public function transferBoardOwnership(int \$boardId, string \$newOwner, bool \$changeContent = false): Board {
		if (!self::gantaraCanShareWith(Acl::PERMISSION_TYPE_USER, \$newOwner)) {
			{$refused}
		}
		\$this->connection->beginTransaction();
PHP);

	patch($importService, <<<'PHP'
		$aclList = $this->getImportSystem()->getAclList();
		foreach ($aclList as $code => $acl) {
PHP, <<<'PHP'
		$aclList = array_filter(
			$this->getImportSystem()->getAclList(),
			static fn ($acl) => \OCA\Deck\Service\BoardService::gantaraCanShareWith($acl->getType(), (string)$acl->getParticipant()),
		);
		foreach ($aclList as $code => $acl) {
PHP);

	foreach ([$deckJson, $trelloJson] as $system) {
		patch($system, <<<'PHP'
 = $this->userManager->get($nextcloudUid);
PHP, <<<'PHP'
 = \OCA\Deck\Service\BoardService::gantaraVisibleUser($nextcloudUid);
PHP);
	}

	patch($deckJson, <<<'PHP'
		if ($this->userManager->userExists($uid)) {
PHP, <<<'PHP'
		if (\OCA\Deck\Service\BoardService::gantaraVisibleUser((string)$uid) !== null) {
PHP);

	patch($deckJson, <<<'PHP'
		if ($actorType === 'users' && !$this->userManager->userExists($actorId)) {
PHP, <<<'PHP'
		if ($actorType === 'users' && \OCA\Deck\Service\BoardService::gantaraVisibleUser($actorId) === null) {
PHP);

	@unlink("{$deck}/appinfo/signature.json");
}

foreach (array_keys($patched) as $file) {
	$out = [];
	exec('php -l ' . escapeshellarg($file) . ' 2>&1', $out, $rc);
	if ($rc !== 0) {
		fwrite(STDERR, "patch-isolation: ERROR {$file} no longer parses:\n" . implode("\n", $out) . "\n");
		exit(1);
	}
	echo "patch-isolation: patched {$file}\n";
}
echo "patch-isolation: done\n";

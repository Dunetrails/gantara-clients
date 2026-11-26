<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Dunetrails
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\GantaraIsolation\Service;

use OCP\IGroupManager;
use OCP\IUser;
use OCP\IUserManager;
use OCP\IUserSession;
use OCP\Share\IManager as IShareManager;

/**
 * The Files sharing rule, for the signed-in account. Everything answers "allowed" when
 * shareapi_only_share_with_group_members is off or nobody is signed in (occ, cron, public links).
 * An unknown account or group answers exactly like one the user may not see.
 */
class Policy {
	/** Deck's Acl::PERMISSION_TYPE_* values. */
	public const DECK_USER = 0;
	public const DECK_GROUP = 1;

	public function __construct(
		private IShareManager $shareManager,
		private IUserSession $userSession,
		private IGroupManager $groupManager,
		private IUserManager $userManager,
	) {
	}

	/** The account the rule applies to, or null when it does not apply. */
	public function subject(): ?IUser {
		if (!$this->shareManager->shareWithGroupMembersOnly()) {
			return null;
		}
		return $this->userSession->getUser();
	}

	public function isActive(): bool {
		return $this->subject() !== null;
	}

	public function isAdmin(): bool {
		$me = $this->subject();
		return $me !== null && $this->groupManager->isAdmin($me->getUID());
	}

	public function canSeeUser(IUser $target): bool {
		$me = $this->subject();
		if ($me === null || $me->getUID() === $target->getUID()) {
			return true;
		}
		return Rule::shareAGroup(
			$this->groupManager->getUserGroupIds($me),
			$this->groupManager->getUserGroupIds($target),
			$this->shareManager->shareWithGroupMembersOnlyExcludeGroupsList(),
		);
	}

	public function canSeeUid(string $uid): bool {
		$me = $this->subject();
		if ($me === null || $uid === $me->getUID()) {
			return true;
		}
		$target = $this->userManager->get($uid);
		return $target !== null && $this->canSeeUser($target);
	}

	/**
	 * A group is visible to its members. $forSharing also refuses a group on the exclusion list,
	 * as a Files group share does. Path lookups must not: Sabre resolves every group the user is in
	 * when it computes their ACL.
	 */
	public function canSeeGroup(string $gid, bool $forSharing): bool {
		$me = $this->subject();
		if ($me === null) {
			return true;
		}
		$group = $this->groupManager->get($gid);
		if ($group === null || !$group->inGroup($me)) {
			return false;
		}
		return !$forSharing
			|| !in_array($group->getGID(), $this->shareManager->shareWithGroupMembersOnlyExcludeGroupsList(), true);
	}

	public function isExcludedGroup(string $gid): bool {
		return in_array($gid, $this->shareManager->shareWithGroupMembersOnlyExcludeGroupsList(), true);
	}

	/**
	 * Whether the user may give a Deck board to this participant. Remote (federated) and Teams
	 * participants are refused while the rule applies: federation is off where it does, and a
	 * Team is not a Nextcloud group.
	 */
	public function canShareDeck(int $type, string $participant): bool {
		if (!$this->isActive()) {
			return true;
		}
		return match ($type) {
			self::DECK_USER => $this->canSeeUid($participant),
			self::DECK_GROUP => $this->canSeeGroup($participant, true),
			default => false,
		};
	}
}

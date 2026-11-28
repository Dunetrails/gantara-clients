<?php

declare(strict_types=1);

/**
 * SPDX-FileCopyrightText: 2026 Dunetrails
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace OCA\GantaraMail\Controller;

use InvalidArgumentException;
use OCA\GantaraMail\AppInfo\Application;
use OCA\GantaraMail\Service\AccountRequest;
use OCA\GantaraMail\Service\Provisioner;
use OCA\GantaraMail\Service\UnknownUserException;
use OCP\AppFramework\Http;
use OCP\AppFramework\Http\Attribute\ApiRoute;
use OCP\AppFramework\Http\DataResponse;
use OCP\AppFramework\OCS\OCSBadRequestException;
use OCP\AppFramework\OCS\OCSNotFoundException;
use OCP\AppFramework\OCSController;
use OCP\IRequest;

/**
 * The portal's API. Admin only: no #[NoAdminRequired], so Nextcloud refuses everyone but an admin
 * (the portal's provisioning account) before these methods run.
 *
 *   POST   /ocs/v2.php/apps/gantara_mail/api/v1/accounts  uid, email, name, password
 *   DELETE /ocs/v2.php/apps/gantara_mail/api/v1/accounts?uid=...&email=...
 */
class AccountsController extends OCSController {
	public function __construct(
		IRequest $request,
		private Provisioner $provisioner,
	) {
		parent::__construct(Application::APP_ID, $request);
	}

	/**
	 * Create the user's Mail account for the mailbox, or set the new password on the one they have.
	 *
	 * @return DataResponse<Http::STATUS_OK, array{id: int, created: bool}, array{}>
	 */
	#[ApiRoute(verb: 'POST', url: '/api/v1/accounts')]
	public function upsert(string $uid = '', string $email = '', string $name = '', string $password = ''): DataResponse {
		try {
			$r = AccountRequest::forUpsert($uid, $email, $name, $password);
		} catch (InvalidArgumentException $e) {
			throw new OCSBadRequestException($e->getMessage());
		}
		try {
			return new DataResponse($this->provisioner->upsert($r));
		} catch (UnknownUserException) {
			throw new OCSNotFoundException('unknown user');
		}
	}

	/**
	 * Remove the user's Mail account(s) for the address. Idempotent.
	 *
	 * @return DataResponse<Http::STATUS_OK, array{deleted: int}, array{}>
	 */
	#[ApiRoute(verb: 'DELETE', url: '/api/v1/accounts')]
	public function remove(string $uid = '', string $email = ''): DataResponse {
		try {
			$r = AccountRequest::forRemove($uid, $email);
		} catch (InvalidArgumentException $e) {
			throw new OCSBadRequestException($e->getMessage());
		}
		return new DataResponse($this->provisioner->remove($r));
	}
}

/**
 * Linux tray that does not use Electron's Chromium StatusNotifier multiplexer.
 * Spawns branding/sni_tray.py (copied next to the AppImage binary) which exports
 * a real /StatusNotifierItem via Gio so GNOME AppIndicator can parse IconPixmap.
 *
 * Host python3 must not inherit Electron's LD_LIBRARY_PATH / GI_TYPELIB_PATH or
 * pygobject loads the bundled GLib and never prints READY.
 */
const { app, Menu, nativeImage } = require('electron')
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { getTrayIcon } = require('../shared/icons.utils.js')

const LOG_PATH = '/tmp/dunetrails-talk-sni.log'

function sniLog(msg) {
	console.error('Linux SNI tray:', msg)
	try {
		fs.appendFileSync(LOG_PATH, `linux-sni-tray: ${msg}\n`)
	} catch {
		// ignore
	}
}

function findPython() {
	for (const p of ['/usr/bin/python3', '/bin/python3']) {
		if (fs.existsSync(p)) {
			return p
		}
	}
	return null
}

function findScript() {
	const candidates = [
		process.env.APPDIR && path.join(process.env.APPDIR, 'sni_tray.py'),
		path.join(path.dirname(process.execPath), 'sni_tray.py'),
		path.join(process.resourcesPath, 'sni_tray.py'),
		path.join(__dirname, 'sni_tray.py'),
	].filter(Boolean)
	return candidates.find((p) => fs.existsSync(p)) || null
}

function resolveIconPath() {
	const rel = getTrayIcon()
	return [
		path.join(__dirname, rel),
		path.join(app.getAppPath(), '.webpack/main', rel),
		path.join(app.getAppPath(), '.webpack/main/img/icons/IconTrayLinux.png'),
		path.join(__dirname, 'img/icons/IconTrayLinux.png'),
	]
}

function loadTrayImage() {
	for (const candidate of resolveIconPath()) {
		try {
			if (!fs.existsSync(candidate) && !candidate.includes('app.asar')) {
				continue
			}
			const image = nativeImage.createFromPath(candidate)
			if (!image.isEmpty()) {
				return image.resize({ width: 32, height: 32 })
			}
		} catch {
			// try next
		}
	}
	return nativeImage.createEmpty()
}

function writePixmap(image, dest) {
	const { width, height } = image.getSize()
	const bgra = image.toBitmap()
	const out = Buffer.alloc(8 + width * height * 4)
	out.writeUInt32LE(width, 0)
	out.writeUInt32LE(height, 4)
	for (let i = 0; i < width * height; i++) {
		const o = i * 4
		out[8 + o] = bgra[o + 3]
		out[8 + o + 1] = bgra[o + 2]
		out[8 + o + 2] = bgra[o + 1]
		out[8 + o + 3] = bgra[o]
	}
	fs.writeFileSync(dest, out)
}

/** Session D-Bus + locale only. Electron's library paths break host python3-gi. */
function hostPythonEnv() {
	const keep = [
		'HOME',
		'USER',
		'LOGNAME',
		'LANG',
		'LC_ALL',
		'LC_CTYPE',
		'LC_MESSAGES',
		'LANGUAGE',
		'TZ',
		'DISPLAY',
		'WAYLAND_DISPLAY',
		'XDG_RUNTIME_DIR',
		'XDG_SESSION_TYPE',
		'XDG_CURRENT_DESKTOP',
		'XDG_SESSION_DESKTOP',
		'XDG_SESSION_CLASS',
		'DBUS_SESSION_BUS_ADDRESS',
		'DBUS_STARTER_ADDRESS',
		'DBUS_STARTER_BUS_TYPE',
		'XAUTHORITY',
		'GNOME_DESKTOP_SESSION_ID',
		'DESKTOP_SESSION',
	]
	const env = {
		PATH: '/usr/bin:/bin:/usr/local/bin',
		PYTHONUNBUFFERED: '1',
		PYTHONDONTWRITEBYTECODE: '1',
	}
	for (const key of keep) {
		if (process.env[key]) {
			env[key] = process.env[key]
		}
	}
	return env
}

/** How long the helper gets to export the item before we stop waiting on it. */
const READY_TIMEOUT_MS = 15000

/** Must match MENU_ITEMS in sni_tray.py. */
const MENU_OPEN = 1
const MENU_QUIT = 2

/**
 * @param {import('electron').BrowserWindow} browserWindow
 * @param {() => void} onUnavailable Called if the helper never comes up, so the
 *   caller can fall back to Electron's own Tray. python3-gi is not installed
 *   everywhere, and spawn() succeeds long before the import that needs it.
 * @return {import('node:child_process').ChildProcess | null}
 */
function setupLinuxSniTray(browserWindow, onUnavailable = () => {}) {
	const python = findPython()
	const script = findScript()
	if (!python || !script) {
		sniLog(`python3 or sni_tray.py missing python=${python} script=${script}`)
		return null
	}

	const args = ['-u', script, '--title', app.name]
	const image = loadTrayImage()
	if (image.isEmpty()) {
		sniLog('tray PNG failed to load; helper will use its built-in pixmap')
	} else {
		const pixmapPath = path.join(os.tmpdir(), 'dunetrails-talk-tray.argb')
		try {
			writePixmap(image, pixmapPath)
			args.push('--icon', pixmapPath)
		} catch (err) {
			sniLog(`pixmap write failed (${err}); helper will use its built-in pixmap`)
		}
	}

	sniLog(`spawn ${python} ${args.join(' ')}`)
	const child = spawn(python, args, {
		stdio: ['pipe', 'pipe', 'pipe'],
		env: hostPythonEnv(),
	})
	// Writing to a helper that already exited fails asynchronously with EPIPE. A stream
	// 'error' without a listener is an uncaught exception in the main process, which
	// Electron reports as a crash — typically on quit, when the helper goes first.
	child.stdin.on('error', (err) => sniLog(`stdin: ${err.message}`))

	// Events from the helper can still arrive while the window is being torn down.
	const showWindow = () => {
		if (!browserWindow.isDestroyed()) {
			browserWindow.show()
		}
	}

	const menu = Menu.buildFromTemplate([
		{ label: 'Open', click: showWindow },
		{ role: 'quit' },
	])

	let ready = false
	let settled = false
	let stopping = false
	let readyTimer = null

	const giveUp = (why) => {
		if (settled) {
			return
		}
		settled = true
		clearTimeout(readyTimer)
		try {
			child.kill()
		} catch {
			// ignore
		}
		if (stopping || browserWindow.isDestroyed()) {
			return
		}
		sniLog(`${why} — falling back to Electron's tray`)
		onUnavailable()
	}

	readyTimer = setTimeout(
		() => giveUp(`no READY within ${READY_TIMEOUT_MS}ms`),
		READY_TIMEOUT_MS,
	)
	readyTimer.unref?.()

	child.stdout.setEncoding('utf8')
	child.stdout.on('data', (chunk) => {
		for (const line of String(chunk).split('\n')) {
			if (line.startsWith('READY')) {
				ready = true
				settled = true
				clearTimeout(readyTimer)
				sniLog(line.trim())
			} else if (line.startsWith('WATCHER none')) {
				sniLog('no tray host answered; the icon will appear if one starts later')
			} else if (line.startsWith('EVENT activate')) {
				showWindow()
			} else if (line.startsWith('EVENT menu ')) {
				// GNOME renders the menu itself from the helper's dbusmenu and
				// reports the click back, so there is no Electron menu to popup.
				const id = Number(line.slice('EVENT menu '.length).trim())
				if (id === MENU_OPEN) {
					showWindow()
				} else if (id === MENU_QUIT) {
					app.quit()
				}
			} else if (line.startsWith('EVENT context') && !browserWindow.isDestroyed()) {
				menu.popup({ window: browserWindow })
			}
		}
	})
	child.stderr.setEncoding('utf8')
	child.stderr.on('data', (chunk) => {
		const text = String(chunk)
		process.stderr.write(text)
		try {
			fs.appendFileSync(LOG_PATH, text)
		} catch {
			// ignore
		}
	})
	child.on('error', (err) => {
		giveUp(`spawn error: ${err}`)
	})
	child.on('exit', (code, signal) => {
		if (stopping || ready) {
			return
		}
		giveUp(`exited before READY code=${code} signal=${signal} — see ${LOG_PATH}`)
	})

	// Runs on both before-quit and window 'closed', so it must be idempotent. Ask the
	// helper to leave (it unregisters the item and exits) instead of killing it in the
	// middle of the write; kill only if it is still around after a grace period.
	const stop = () => {
		if (stopping) {
			return
		}
		stopping = true
		clearTimeout(readyTimer)
		app.off('before-quit', stop)
		if (child.exitCode !== null || child.signalCode !== null) {
			return
		}
		if (child.stdin.writable) {
			child.stdin.end('QUIT\n')
		}
		const killTimer = setTimeout(() => {
			try {
				child.kill()
			} catch {
				// ignore
			}
		}, 2000)
		killTimer.unref?.()
		child.once('exit', () => clearTimeout(killTimer))
	}
	app.on('before-quit', stop)
	browserWindow.once('closed', stop)

	return child
}

module.exports = {
	setupLinuxSniTray,
}

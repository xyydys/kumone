// The JavaScript half of the LX Music custom-source host.
//
// It builds `globalThis.lx` — the API surface LX Music's user scripts are
// written against (EVENT_NAMES, request, on, send, utils, currentScriptInfo,
// version, env) — plus the browser-ish globals those scripts lean on
// (console, timers, atob/btoa). Everything that needs the platform goes
// through `__lx_native`, a handful of Swift blocks taking and returning plain
// strings and numbers; JS values never cross into Swift, so nothing on the
// native side has to keep a JSValue alive.
//
// `__lx_internal` is the way back in: Swift calls it to deliver an HTTP
// response, fire a timer, or dispatch a request (`musicUrl`, `search`,
// `lyric`) to the script's handler.

enum LXScriptPreload {
    static let source = #"""
(function () {
  'use strict'
  const native = globalThis.__lx_native
  delete globalThis.__lx_native

  // ---------- bytes ----------
  const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  const B64_LOOKUP = new Uint8Array(256)
  for (let i = 0; i < B64.length; i++) B64_LOOKUP[B64.charCodeAt(i)] = i

  function bytesToBase64(bytes) {
    let out = ''
    let i = 0
    for (; i + 2 < bytes.length; i += 3) {
      const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63]
    }
    if (i < bytes.length) {
      const rest = bytes.length - i
      const n = (bytes[i] << 16) | (rest > 1 ? bytes[i + 1] << 8 : 0)
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63]
      out += rest > 1 ? B64[(n >> 6) & 63] + '=' : '=='
    }
    return out
  }

  function base64ToBytes(str) {
    const clean = String(str).replace(/[^A-Za-z0-9+/]/g, '')
    const out = new Uint8Array(Math.floor(clean.length * 3 / 4))
    let o = 0
    for (let i = 0; i < clean.length; i += 4) {
      const a = B64_LOOKUP[clean.charCodeAt(i)]
      const b = B64_LOOKUP[clean.charCodeAt(i + 1)]
      const c = B64_LOOKUP[clean.charCodeAt(i + 2)]
      const d = B64_LOOKUP[clean.charCodeAt(i + 3)]
      const n = (a << 18) | (b << 12) | (c << 6) | d
      if (o < out.length) out[o++] = (n >> 16) & 255
      if (i + 2 < clean.length && o < out.length) out[o++] = (n >> 8) & 255
      if (i + 3 < clean.length && o < out.length) out[o++] = n & 255
    }
    return out.subarray(0, o)
  }

  function utf8Encode(str) {
    str = String(str)
    const out = []
    for (let i = 0; i < str.length; i++) {
      let c = str.charCodeAt(i)
      if (c >= 0xd800 && c < 0xdc00 && i + 1 < str.length) {
        const d = str.charCodeAt(i + 1)
        if (d >= 0xdc00 && d < 0xe000) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++ }
      }
      if (c < 0x80) out.push(c)
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63))
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
    }
    return new Uint8Array(out)
  }

  function utf8Decode(bytes) {
    let out = ''
    for (let i = 0; i < bytes.length;) {
      const a = bytes[i++]
      let c
      if (a < 0x80) c = a
      else if (a < 0xe0) c = ((a & 31) << 6) | (bytes[i++] & 63)
      else if (a < 0xf0) c = ((a & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63)
      else c = ((a & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63)
      if (c > 0xffff) { c -= 0x10000; out += String.fromCharCode(0xd800 + (c >> 10), 0xdc00 + (c & 1023)) }
      else out += String.fromCharCode(c)
    }
    return out
  }

  function latin1ToBytes(str) {
    str = String(str)
    const out = new Uint8Array(str.length)
    for (let i = 0; i < str.length; i++) out[i] = str.charCodeAt(i) & 255
    return out
  }

  function bytesToLatin1(bytes) {
    let out = ''
    for (let i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i])
    return out
  }

  function hexToBytes(str) {
    str = String(str)
    const out = new Uint8Array(Math.floor(str.length / 2))
    for (let i = 0; i < out.length; i++) out[i] = parseInt(str.substr(i * 2, 2), 16) || 0
    return out
  }

  function bytesToHex(bytes) {
    let out = ''
    for (let i = 0; i < bytes.length; i++) out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16)
    return out
  }

  function toBytes(data, encoding) {
    if (data == null) return new Uint8Array(0)
    if (data instanceof Uint8Array) return data
    if (data instanceof ArrayBuffer) return new Uint8Array(data)
    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
    if (Array.isArray(data)) return Uint8Array.from(data)
    if (typeof data === 'object' && data.type === 'Buffer' && Array.isArray(data.data)) return Uint8Array.from(data.data)
    const str = String(data)
    switch (String(encoding || 'utf8').toLowerCase()) {
      case 'hex': return hexToBytes(str)
      case 'base64': return base64ToBytes(str)
      case 'binary':
      case 'latin1': return latin1ToBytes(str)
      default: return utf8Encode(str)
    }
  }

  function bytesToString(bytes, format) {
    switch (String(format || 'utf8').toLowerCase()) {
      case 'hex': return bytesToHex(bytes)
      case 'base64': return bytesToBase64(bytes)
      case 'binary':
      case 'latin1': return bytesToLatin1(bytes)
      default: return utf8Decode(bytes)
    }
  }

  function errorMessage(err) {
    if (err == null) return 'Unknown error'
    if (typeof err === 'string') return err
    if (err.message) return String(err.message)
    try { return JSON.stringify(err) } catch (e) { return String(err) }
  }

  function nativeBytes(result, what) {
    if (result == null) throw new Error(what + ' failed')
    return base64ToBytes(result)
  }

  // ---------- console ----------
  function format(args) {
    return args.map(a => {
      if (typeof a === 'string') return a
      if (a instanceof Error) return a.stack || a.message
      try { return JSON.stringify(a) } catch (e) { return String(a) }
    }).join(' ')
  }
  const log = level => (...args) => native.log(level, format(args))
  globalThis.console = {
    log: log('log'), info: log('info'), debug: log('debug'),
    warn: log('warn'), error: log('error'), trace: log('debug'),
    group: log('log'), groupEnd: () => {}, time: () => {}, timeEnd: () => {},
  }

  // ---------- timers ----------
  let timerSeq = 0
  const timers = new Map()
  globalThis.setTimeout = (fn, ms, ...args) => {
    const id = ++timerSeq
    timers.set(id, { fn, args, interval: 0 })
    native.setTimer(id, Number(ms) || 0)
    return id
  }
  globalThis.setInterval = (fn, ms, ...args) => {
    const id = ++timerSeq
    const delay = Math.max(Number(ms) || 0, 10)
    timers.set(id, { fn, args, interval: delay })
    native.setTimer(id, delay)
    return id
  }
  globalThis.clearTimeout = id => { timers.delete(id) }
  globalThis.clearInterval = id => { timers.delete(id) }
  globalThis.btoa = str => bytesToBase64(latin1ToBytes(str))
  globalThis.atob = str => bytesToLatin1(base64ToBytes(str))

  // ---------- requests ----------
  let requestSeq = 0
  const requests = new Map()

  function request(url, options, callback) {
    if (typeof options === 'function') { callback = options; options = {} }
    options = options || {}
    const id = ++requestSeq
    requests.set(id, typeof callback === 'function' ? callback : () => {})
    const headers = {}
    if (options.headers && typeof options.headers === 'object') {
      for (const key of Object.keys(options.headers)) headers[key] = String(options.headers[key])
    }
    let body = null
    let form = null
    if (options.form != null) form = options.form
    else if (options.formData != null) form = options.formData
    else if (options.body != null) {
      if (typeof options.body === 'string') body = options.body
      else if (options.body instanceof Uint8Array || ArrayBuffer.isView(options.body)) body = { base64: bytesToBase64(toBytes(options.body)) }
      else {
        body = JSON.stringify(options.body)
        if (!Object.keys(headers).some(k => k.toLowerCase() === 'content-type')) headers['Content-Type'] = 'application/json'
      }
    }
    native.request(id, String(url), JSON.stringify({
      method: String(options.method || 'get').toUpperCase(),
      headers,
      body,
      form,
      timeout: Number(options.timeout) || 0,
    }))
    return () => {
      if (requests.delete(id)) native.cancelRequest(id)
    }
  }

  // ---------- lx ----------
  const EVENT_NAMES = Object.freeze({ request: 'request', inited: 'inited', updateAlert: 'updateAlert' })
  const handlers = {}

  const lx = {
    EVENT_NAMES,
    request,
    send(eventName, data) {
      return new Promise((resolve, reject) => {
        if (eventName !== EVENT_NAMES.inited && eventName !== EVENT_NAMES.updateAlert) {
          reject(new Error('The event is not supported: ' + eventName))
          return
        }
        let json
        try { json = JSON.stringify(data == null ? {} : data) } catch (e) { reject(e); return }
        native.send(eventName, json)
        resolve()
      })
    },
    on(eventName, handler) {
      if (eventName !== EVENT_NAMES.request) return Promise.reject(new Error('The event is not supported: ' + eventName))
      if (typeof handler !== 'function') return Promise.reject(new Error('Handler must be a function'))
      handlers.request = handler
      return Promise.resolve()
    },
    utils: {
      crypto: {
        aesEncrypt(buffer, mode, key, iv) {
          return nativeBytes(native.aesEncrypt(bytesToBase64(toBytes(buffer)), String(mode || ''),
            bytesToBase64(toBytes(key)), bytesToBase64(toBytes(iv))), 'aesEncrypt')
        },
        rsaEncrypt(buffer, key) {
          return nativeBytes(native.rsaEncrypt(bytesToBase64(toBytes(buffer)), String(key)), 'rsaEncrypt')
        },
        randomBytes(size) {
          return nativeBytes(native.randomBytes(Math.max(0, size | 0)), 'randomBytes')
        },
        md5(str) {
          return native.md5(bytesToBase64(toBytes(str)))
        },
      },
      buffer: {
        from(data, encoding) { return toBytes(data, encoding) },
        bufToString(buf, format) { return bytesToString(toBytes(buf), format) },
      },
      zlib: {
        inflate(buf) {
          return new Promise((resolve, reject) => {
            try { resolve(nativeBytes(native.inflate(bytesToBase64(toBytes(buf))), 'inflate')) } catch (e) { reject(e) }
          })
        },
        deflate(buf) {
          return new Promise((resolve, reject) => {
            try { resolve(nativeBytes(native.deflate(bytesToBase64(toBytes(buf))), 'deflate')) } catch (e) { reject(e) }
          })
        },
      },
    },
    currentScriptInfo: Object.freeze(JSON.parse(native.scriptInfo())),
    version: '2.0.0',
    env: 'mobile',
  }
  Object.defineProperty(globalThis, 'lx', { value: Object.freeze(lx), writable: false, configurable: false })

  // ---------- the way back in from Swift ----------
  globalThis.__lx_internal = Object.freeze({
    response(id, error, statusCode, statusMessage, headersJSON, text, rawBase64) {
      const callback = requests.get(id)
      if (!callback) return
      requests.delete(id)
      if (error) {
        callback(new Error(error), null, null)
        return
      }
      let body = text
      try { body = JSON.parse(text) } catch (e) {}
      let headers = {}
      try { headers = JSON.parse(headersJSON) } catch (e) {}
      let raw = null
      const resp = {
        statusCode,
        statusMessage,
        headers,
        bytes: Math.floor(rawBase64.length * 3 / 4),
        get raw() { return raw || (raw = base64ToBytes(rawBase64)) },
        body,
      }
      callback(null, resp, body)
    },
    fireTimer(id) {
      const timer = timers.get(id)
      if (!timer) return
      if (timer.interval > 0) native.setTimer(id, timer.interval)
      else timers.delete(id)
      try {
        if (typeof timer.fn === 'function') timer.fn(...timer.args)
      } catch (e) {
        native.log('error', 'Timer callback threw: ' + errorMessage(e))
      }
    },
    dispatch(callID, source, action, infoJSON) {
      const handler = handlers.request
      if (!handler) { native.reject(callID, 'The script did not register a request handler'); return }
      let info = {}
      try { info = JSON.parse(infoJSON) } catch (e) {}
      let result
      try {
        result = handler({ source, action, info })
      } catch (err) {
        native.reject(callID, errorMessage(err))
        return
      }
      Promise.resolve(result).then(value => {
        let json
        try { json = JSON.stringify([value === undefined ? null : value]) } catch (e) {
          native.reject(callID, 'The script returned a value that cannot be serialized')
          return
        }
        native.resolve(callID, json)
      }, err => native.reject(callID, errorMessage(err)))
    },
  })
})()
"""#
}

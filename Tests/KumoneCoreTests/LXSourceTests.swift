import Foundation
import Testing
@testable import KumoneCore

@Suite struct LXScriptInfoTests {
    @Test func parsesTheLeadingCommentLikeLXMusic() {
        let info = LXScriptInfo.parse("""

        /*!
         * @name 测试音源
         * @description 集成 QQ、网易
         * @version v1.2
         * @author someone
         * @homepage https://example.test
         */
        const { EVENT_NAMES } = globalThis.lx
        """)
        #expect(info.name == "测试音源")
        #expect(info.description == "集成 QQ、网易")
        #expect(info.version == "v1.2")
        #expect(info.author == "someone")
        #expect(info.homepage == "https://example.test")
    }

    @Test func scriptWithoutHeaderHasEmptyInfo() {
        let info = LXScriptInfo.parse("globalThis.lx.send('inited', {})")
        #expect(info.name.isEmpty)
        #expect(info.version.isEmpty)
    }
}

@Suite struct LXMusicInfoTests {
    @Test func normalisesTheLegacyLXShape() throws {
        let object: [String: Any] = [
            "name": "晴天", "singer": "周杰伦、杨瑞代", "albumName": "叶惠美", "id": "MUSIC_123",
            "source": "kw", "interval": "04:29", "meta": ["picture": "https://img4.kuwo.cn/a.jpg"],
        ]
        let track = try #require(LXMusicInfo.track(from: object, platform: "kw", platformName: "酷我音乐", scriptID: nil))
        #expect(track.name == "晴天")
        #expect(track.artists.map(\.name) == ["周杰伦", "杨瑞代"])
        #expect(track.album.name == "叶惠美")
        #expect(track.album.picUrl == "https://img4.kuwo.cn/a.jpg")
        #expect(track.durationMS == 269_000)
        #expect(track.id < 0)
        #expect(track.isExternal)
        #expect(track.external?.platform == "kw")
        let info = try #require(track.external?.musicInfoObject)
        #expect(info["songmid"] as? String == "MUSIC_123")
        #expect(info["id"] as? String == "MUSIC_123")
    }

    @Test func normalisesAScriptsOwnShape() throws {
        // 汽水VIP-style: `pic`, duration in seconds, `songmid` already set.
        let object: [String: Any] = [
            "id": "7001", "songmid": "7001", "name": "晴天", "singer": "周杰伦",
            "albumName": "叶惠美", "duration": 269, "pic": "https://p3.example.test/c.jpg",
        ]
        let track = try #require(LXMusicInfo.track(from: object, platform: "qsvip", platformName: "汽水VIP", scriptID: nil))
        #expect(track.durationMS == 269_000)
        #expect(track.album.picUrl == "https://p3.example.test/c.jpg")
    }

    @Test func resultWithoutANameIsDropped() {
        #expect(LXMusicInfo.track(from: ["id": "1"], platform: "kw", platformName: "", scriptID: nil) == nil)
    }

    @Test func syntheticIDsAreStableNegativeAndPerPlatform() {
        let a = LXMusicInfo.syntheticID(platform: "kw", key: "MUSIC_123")
        #expect(a == LXMusicInfo.syntheticID(platform: "kw", key: "MUSIC_123"))
        #expect(a < 0)
        #expect(a != LXMusicInfo.syntheticID(platform: "mg", key: "MUSIC_123"))
    }

    @Test func externalTrackSurvivesTheQueueRoundTrip() throws {
        let track = try #require(LXMusicInfo.track(
            from: ["name": "晴天", "singer": "周杰伦", "songmid": "abc", "interval": "01:02"],
            platform: "mg", platformName: "咪咕音乐", scriptID: UUID()
        ))
        let decoded = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track))
        #expect(decoded == track)
        #expect(decoded.external?.platformName == "咪咕音乐")
    }

    @Test func netEaseSongGetsTheWyShape() throws {
        let json = """
        {"id":186001,"name":"晴天","ar":[{"id":6452,"name":"周杰伦"}],
         "al":{"id":18905,"name":"叶惠美","picUrl":"https://p1.music.126.net/a.jpg"},"dt":269000}
        """
        let track = try JSONDecoder().decode(Track.self, from: Data(json.utf8))
        #expect(!track.isExternal)
        let info = LXMusicInfo.musicInfo(for: track)
        #expect(info["songmid"] as? String == "186001")
        #expect(info["source"] as? String == "wy")
        #expect(info["interval"] as? String == "04:29")
        #expect(info["albumName"] as? String == "叶惠美")
    }

    @Test func qualityStepsDownToWhatTheSourceOffers() {
        #expect(LXMusicInfo.quality(for: .lossless, supported: ["128k", "320k", "flac"]) == "flac")
        #expect(LXMusicInfo.quality(for: .hires, supported: ["128k", "320k", "flac"]) == "flac")
        #expect(LXMusicInfo.quality(for: .higher, supported: ["128k", "320k"]) == "128k")
        #expect(LXMusicInfo.quality(for: .exhigh, supported: []) == "320k")
    }

    @Test func intervals() {
        #expect(LXMusicInfo.seconds(fromInterval: "04:29") == 269)
        #expect(LXMusicInfo.seconds(fromInterval: "1:02:03") == 3723)
        #expect(LXMusicInfo.seconds(fromInterval: "abc") == nil)
    }
}

/// Answers every request from `handler`, so scripts can be run offline.
private final class LXStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct LXScriptRuntimeTests {
    private func runtime(_ script: String) -> LXScriptRuntime {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LXStubProtocol.self]
        return LXScriptRuntime(script: script, info: LXScriptInfo.parse(script), session: URLSession(configuration: configuration))
    }

    @Test func initedRegistersSourcesAndRequestsResolve() async throws {
        LXStubProtocol.handler = { request in
            // Headers from the script must arrive; without them the URL below is never returned.
            guard request.value(forHTTPHeaderField: "X-Test") == "1" else { return (400, Data()) }
            return (200, Data(#"{"url":"https://cdn.example.test/a.mp3","list":[{"name":"晴天","singer":"周杰伦","songmid":"1"}]}"#.utf8))
        }
        let runtime = runtime("""
        /*! @name stub */
        const { EVENT_NAMES, request, on, send } = globalThis.lx
        const get = url => new Promise((resolve, reject) => {
          request(url, { method: 'get', headers: { 'X-Test': '1' } }, (err, resp) => err ? reject(err) : resolve(resp.body))
        })
        on(EVENT_NAMES.request, async ({ source, action, info }) => {
          const body = await get('https://api.example.test/x?id=' + (info.musicInfo ? info.musicInfo.songmid : info.keyword))
          if (action === 'musicUrl') return body.url
          if (action === 'search') return { list: body.list, isEnd: true }
          if (action === 'lyric') return new Promise(resolve => setTimeout(() => resolve({ lyric: '[00:01.00]hi' }), 10))
          throw new Error('unsupported ' + action)
        })
        on('showConfigView', () => {}) // not an LX event: must not stop the script
        send(EVENT_NAMES.inited, { sources: {
          kw: { name: '酷我音乐', type: 'music', actions: ['musicUrl', 'search', 'lyric'], qualitys: ['128k', '320k'] },
        } })
        """)
        let sources = try await runtime.start()
        #expect(sources.map(\.id) == ["kw"])
        #expect(sources.first?.searchAction == "search")

        let url = try await runtime.call(source: "kw", action: "musicUrl", info: ["type": "320k", "musicInfo": ["songmid": "1"]])
        #expect(url.string == "https://cdn.example.test/a.mp3")

        let search = try await runtime.call(source: "kw", action: "search", info: ["keyword": "晴天", "page": 1, "limit": 20])
        #expect((search.dictionary?["list"] as? [Any])?.count == 1)

        let lyric = try await runtime.call(source: "kw", action: "lyric", info: ["musicInfo": ["songmid": "1"]])
        #expect(lyric.dictionary?["lyric"] as? String == "[00:01.00]hi")

        await #expect(throws: LXScriptError.script("unsupported pic")) {
            try await runtime.call(source: "kw", action: "pic", info: [:])
        }
        runtime.stop()
    }

    @Test func syntaxErrorFailsStart() async {
        let runtime = runtime("this is not javascript (")
        await #expect(throws: (any Error).self) {
            try await runtime.start(timeout: 3)
        }
    }

    @Test func scriptThatNeverInitsTimesOut() async {
        let runtime = runtime("globalThis.lx.on('request', () => null)")
        await #expect(throws: LXScriptError.initTimeout) {
            try await runtime.start(timeout: 0.5)
        }
    }

    @Test func utilsMatchNode() async throws {
        let runtime = runtime("""
        const { utils, send, on, EVENT_NAMES } = globalThis.lx
        on(EVENT_NAMES.request, () => [
          utils.crypto.md5('abc'),
          utils.buffer.bufToString(utils.buffer.from('你好', 'utf8'), 'hex'),
          utils.buffer.bufToString(utils.crypto.aesEncrypt(utils.buffer.from('hello'), 'aes-128-ecb', utils.buffer.from('0123456789abcdef'), ''), 'base64'),
          btoa('hi'),
        ])
        send(EVENT_NAMES.inited, { sources: { wy: { name: '网易云音乐', type: 'music', actions: ['musicUrl'], qualitys: [] } } })
        """)
        _ = try await runtime.start()
        let value = try await runtime.call(source: "wy", action: "musicUrl", info: [:])
        let results = try #require(value.array as? [String])
        #expect(results[0] == "900150983cd24fb0d6963f7d28e17f72")
        #expect(results[1] == "e4bda0e5a5bd")
        // printf hello | openssl enc -aes-128-ecb -K 30313233343536373839616263646566 | base64
        #expect(results[2] == "Z0x+8454yr2c7JwSWCOmOQ==")
        #expect(results[3] == "aGk=")
        runtime.stop()
    }
}

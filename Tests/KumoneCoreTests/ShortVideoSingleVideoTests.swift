import Foundation
import Testing
@testable import KumoneCore

@Suite("Short video single-video parsing")
struct ShortVideoSingleVideoTests {
    private let awemeID = "7464115130314394940"

    @Test func extractsIDFromVideoURL() {
        #expect(ShortVideoSingleVideo.awemeID(
            from: "https://www.douyin.com/video/\(awemeID)"
        ) == awemeID)
        #expect(ShortVideoSingleVideo.awemeID(
            from: "https://www.douyin.com/share/video/\(awemeID)"
        ) == awemeID)
    }

    @Test func extractsIDFromShareTextWithQueryParameters() {
        let shareText = "7.43 复制打开抖音，看看【夹具作者的作品】"
            + "https://www.douyin.com/video/\(awemeID)?previous_page=app_code_link"
            + "&enter_from=short_link 复制此链接"
        #expect(ShortVideoSingleVideo.awemeID(from: shareText) == awemeID)
        #expect(ShortVideoSingleVideo.awemeID(
            from: "https://www.douyin.com/?modal_id=\(awemeID)&previous_page=search"
        ) == awemeID)
    }

    @Test func resolvesDouyinShortLinkID() async throws {
        let shareText = "复制打开抖音 https://v.douyin.com/sLDScR/ 看看这个作品"
        let link = ShortVideoSingleVideo.shortLink(in: shareText)
        #expect(link?.absoluteString == "https://v.douyin.com/sLDScR/")

        let destination = try #require(URL(
            string: "https://www.douyin.com/share/forward/6792858421352729859/?region=CN"
        ))
        let id = await ShortVideoSingleVideo.awemeID(fromShareText: shareText) { link in
            #expect(link.absoluteString == "https://v.douyin.com/sLDScR/")
            return destination
        }
        #expect(id == "6792858421352729859")
    }

    @Test func mapsItemInfoJSON() throws {
        let video = try #require(ShortVideoSingleVideo.video(
            fromItemInfo: Data(Self.itemInfoJSON.utf8)
        ))
        #expect(video.id == awemeID)
        #expect(video.desc == "夹具作品")
        #expect(video.author == "夹具作者")
        #expect(video.cover == "https://example.com/cover.jpg")
        #expect(video.durationMS == 12345)
        #expect(video.playURL == "https://example.com/play.mp4")
        #expect(video.videoID == "v0300fg10000cj2m3k3c77u7v6k0")
    }

    @Test func mapsDetailJSON() throws {
        let video = try #require(ShortVideoSingleVideo.video(
            fromDetail: Data(Self.detailJSON.utf8)
        ))
        #expect(video.id == awemeID)
        #expect(video.desc == "详情夹具")
        #expect(video.author == "详情作者")
        #expect(video.cover == "https://example.com/detail-cover.jpg")
        #expect(video.durationMS == 9876)
        #expect(video.playURL == "https://example.com/detail.mp4")
        #expect(video.videoID == "v0300detail")
    }

    private static let itemInfoJSON = """
    {
      "aweme_list": [
        {
          "aweme_id": "7464115130314394940",
          "desc": "夹具作品",
          "author": { "nickname": "夹具作者" },
          "video": {
            "duration": 12345,
            "play_addr": {
              "uri": "v0300fg10000cj2m3k3c77u7v6k0",
              "url_list": ["https://example.com/play.mp4"]
            },
            "cover": { "url_list": ["https://example.com/cover.jpg"] }
          }
        }
      ]
    }
    """

    private static let detailJSON = """
    {
      "aweme_detail": {
        "aweme_id": "7464115130314394940",
        "desc": "详情夹具",
        "author": { "nickname": "详情作者" },
        "video": {
          "duration": 9876,
          "play_addr": {
            "uri": "v0300detail",
            "url_list": ["https://example.com/detail.mp4"]
          },
          "origin_cover": {
            "url_list": ["https://example.com/detail-cover.jpg"]
          }
        }
      }
    }
    """
}

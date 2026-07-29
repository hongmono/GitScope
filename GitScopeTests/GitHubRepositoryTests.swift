import XCTest

/// `GitHubRepository.init?(remoteURL:)` 의 remote URL 파싱 특성화 테스트.
final class GitHubRepositoryTests: XCTestCase {

    // MARK: - HTTPS 형태

    func testParsesHTTPSRemoteWithGitSuffix() {
        let repository = GitHubRepository(remoteURL: "https://github.com/hongmono/GitScope.git")
        XCTAssertEqual(repository?.owner, "hongmono")
        XCTAssertEqual(repository?.name, "GitScope")
    }

    func testParsesHTTPSRemoteWithoutGitSuffix() {
        let repository = GitHubRepository(remoteURL: "https://github.com/hongmono/GitScope")
        XCTAssertEqual(repository?.owner, "hongmono")
        XCTAssertEqual(repository?.name, "GitScope")
    }

    func testParsesHTTPSRemoteWithCredentialsAndMixedCaseHost() {
        let repository = GitHubRepository(remoteURL: "https://user@GitHub.COM/Owner/Repo.git")
        XCTAssertEqual(repository?.owner, "Owner")
        XCTAssertEqual(repository?.name, "Repo")
    }

    func testTrimsSurroundingWhitespace() {
        let repository = GitHubRepository(remoteURL: "  https://github.com/hongmono/GitScope.git\n")
        XCTAssertEqual(repository?.owner, "hongmono")
        XCTAssertEqual(repository?.name, "GitScope")
    }

    // MARK: - SSH 형태

    func testParsesSCPStyleSSHRemote() {
        let repository = GitHubRepository(remoteURL: "git@github.com:hongmono/GitScope.git")
        XCTAssertEqual(repository?.owner, "hongmono")
        XCTAssertEqual(repository?.name, "GitScope")
    }

    func testParsesSCPStyleSSHRemoteWithoutGitSuffix() {
        let repository = GitHubRepository(remoteURL: "git@github.com:hongmono/GitScope")
        XCTAssertEqual(repository?.owner, "hongmono")
        XCTAssertEqual(repository?.name, "GitScope")
    }

    func testParsesSCPStyleRemoteWithoutUser() {
        // `~/.gitconfig` 의 insteadOf 치환 등으로 사용자 부분이 빠진 scp 형태도 유효한 remote 다.
        let repository = GitHubRepository(remoteURL: "github.com:hongmono/GitScope.git")
        XCTAssertEqual(repository?.owner, "hongmono")
        XCTAssertEqual(repository?.name, "GitScope")
    }

    func testParsesSCPStyleRemoteWithoutUserAndMixedCaseHost() {
        let repository = GitHubRepository(remoteURL: "GitHub.COM:Owner/Repo")
        XCTAssertEqual(repository?.owner, "Owner")
        XCTAssertEqual(repository?.name, "Repo")
    }

    func testParsesSSHSchemeRemote() {
        let repository = GitHubRepository(remoteURL: "ssh://git@github.com/hongmono/GitScope.git")
        XCTAssertEqual(repository?.owner, "hongmono")
        XCTAssertEqual(repository?.name, "GitScope")
    }

    // MARK: - 거부해야 하는 입력

    func testRejectsNonGitHubHosts() {
        XCTAssertNil(GitHubRepository(remoteURL: "https://gitlab.com/owner/repo.git"))
        XCTAssertNil(GitHubRepository(remoteURL: "git@gitlab.com:owner/repo.git"))
        XCTAssertNil(GitHubRepository(remoteURL: "https://github.evil.com/owner/repo.git"))
    }

    func testRejectsPathsWithoutExactlyOwnerAndName() {
        XCTAssertNil(GitHubRepository(remoteURL: "https://github.com/owner"))
        XCTAssertNil(GitHubRepository(remoteURL: "https://github.com/owner/repo/extra"))
        XCTAssertNil(GitHubRepository(remoteURL: "git@github.com:owner"))
    }

    func testRejectsEmptyOrBlankInput() {
        XCTAssertNil(GitHubRepository(remoteURL: ""))
        XCTAssertNil(GitHubRepository(remoteURL: "   \n"))
    }

    func testRejectsSCPFormWithoutUserOnNonGitHubHost() {
        XCTAssertNil(GitHubRepository(remoteURL: "gitlab.com:owner/repo.git"))
        XCTAssertNil(GitHubRepository(remoteURL: "github.evil.com:owner/repo.git"))
    }

    func testRejectsRepositoryNamedOnlyGitSuffix() {
        // 이름이 ".git" 뿐이면 접미사를 떼고 나면 빈 이름이라 거부된다.
        XCTAssertNil(GitHubRepository(remoteURL: "https://github.com/owner/.git"))
    }

    // MARK: - 파생 URL

    func testDerivedWebAndAPIURLs() {
        let repository = GitHubRepository(remoteURL: "git@github.com:hongmono/GitScope.git")
        XCTAssertEqual(
            repository?.webURL.absoluteString,
            "https://github.com/hongmono/GitScope"
        )
        XCTAssertEqual(
            repository?.apiURL.absoluteString,
            "https://api.github.com/repos/hongmono/GitScope"
        )
    }
}

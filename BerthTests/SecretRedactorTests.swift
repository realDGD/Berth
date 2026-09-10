import XCTest
@testable import Berth

final class SecretRedactorTests: XCTestCase {
    func testPrivateKeyBlockIsRedacted() {
        let output = """
        $ cat ~/.ssh/id_ed25519
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACB6Q1x8s3qQ0d0v9v0tQ6y9m5eYQ7rj9rX1vP0S2Rq5jQAAAJgQ
        -----END OPENSSH PRIVATE KEY-----
        done
        """
        let redacted = SecretRedactor.redact(output)
        XCTAssertFalse(redacted.contains("BEGIN OPENSSH PRIVATE KEY"))
        XCTAssertFalse(redacted.contains("b3BlbnNzaC1rZXktdjEAAAAABG5vbmUA"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
        XCTAssertTrue(redacted.hasPrefix("$ cat ~/.ssh/id_ed25519"))
        XCTAssertTrue(redacted.hasSuffix("done"))
    }

    func testWellKnownTokensAreRedacted() {
        let output = """
        AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
        GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789ABCD
        Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U
        slack=xoxb-123456789012-abcdefghijkl
        """
        let redacted = SecretRedactor.redact(output)
        XCTAssertFalse(redacted.contains("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertFalse(redacted.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
        XCTAssertFalse(redacted.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        XCTAssertFalse(redacted.contains("xoxb-123456789012-abcdefghijkl"))
        // 键名保留,模型仍能看出结构
        XCTAssertTrue(redacted.contains("AWS_ACCESS_KEY_ID="))
        XCTAssertTrue(redacted.contains("GITHUB_TOKEN="))
    }

    func testKeyValueSecretsKeepKeyAndDropValue() {
        let redacted = SecretRedactor.redact("DB_PASSWORD=hunter22\napi_key: 'abcd1234efgh'\nname=alice")
        XCTAssertTrue(redacted.contains("DB_PASSWORD=[REDACTED]"))
        XCTAssertTrue(redacted.contains("api_key: [REDACTED]"))
        XCTAssertFalse(redacted.contains("hunter22"))
        XCTAssertFalse(redacted.contains("abcd1234efgh"))
        XCTAssertTrue(redacted.contains("name=alice"))
    }

    func testShadowHashesAndURLPasswordsAreRedacted() {
        let redacted = SecretRedactor.redact("""
        root:$6$rounds=5000$saltsalt$hashhashhashhashhashhashhash:19000:0:99999:7:::
        DATABASE_URL=postgres://app:s3cr3tpw@db.internal:5432/app
        """)
        XCTAssertFalse(redacted.contains("$6$rounds"))
        XCTAssertFalse(redacted.contains("s3cr3tpw"))
        XCTAssertTrue(redacted.contains("postgres://app:[REDACTED]@db.internal"))
    }

    func testOrdinaryOutputIsUntouched() {
        let text = "total 12\ndrwxr-xr-x 3 root root 4096 Sep  9 10:00 srv\nnginx: active (running)"
        XCTAssertEqual(SecretRedactor.redact(text), text)
    }
}

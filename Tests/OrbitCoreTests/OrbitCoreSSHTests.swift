import Foundation
import Testing
@testable import OrbitCore

struct OrbitCoreSSHTests {
    @Test
    func sshConfigParsing() {
        let config = """
        Host gpu-cluster
          HostName login.cluster.edu
          User alice
          Port 2222
          IdentityFile ~/.ssh/id_ed25519
          ProxyJump bastion
        """

        let parsed = SSHKeyDetector.parseConfig(content: config, hostname: "gpu-cluster")
        #expect(parsed?.hostName == "login.cluster.edu")
        #expect(parsed?.user == "alice")
        #expect(parsed?.port == 2222)
        #expect(parsed?.identityFile?.hasSuffix(".ssh/id_ed25519") == true)
    }

    @Test
    func sshConnectionPoolRebuildsConnectionWhenProfileConfigChanges() async {
        let pool = SSHConnectionPool()
        let sharedID = UUID()

        let firstProfile = ClusterProfile(
            id: sharedID,
            displayName: "pool",
            hostname: "hpc-a",
            username: "alice",
            sshKeyPath: "~/.ssh/id_ed25519",
            useSSHConfig: false
        )

        let first = await pool.connection(for: firstProfile)
        let same = await pool.connection(for: firstProfile)
        #expect(first === same)

        var changed = firstProfile
        changed.hostname = "hpc-b"

        let replaced = await pool.connection(for: changed)
        #expect(!(first === replaced))

        await pool.removeConnection(for: sharedID)
        let recreated = await pool.connection(for: changed)
        #expect(!(replaced === recreated))

        await pool.teardownAll()
    }
}

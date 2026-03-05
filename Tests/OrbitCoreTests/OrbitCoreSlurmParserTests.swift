import Foundation
import Testing
@testable import OrbitCore

struct OrbitCoreSlurmParserTests {
    @Test
    func commandBuilderValidation() throws {
        #expect(SlurmCommandBuilder.isValidUsername("alice_01"))
        #expect(!SlurmCommandBuilder.isValidUsername("alice;rm"))
        #expect(SlurmCommandBuilder.isValidJobID("12345_1"))
        #expect(!SlurmCommandBuilder.isValidJobID("$(hack)"))

        let builder = try SlurmCommandBuilder(mode: .unknown, username: "alice")
        #expect(builder.squeueCommand == "squeue --user=alice --json")
        #expect(SlurmCommandBuilder.slurmVersionCommand == "sinfo --version")
        #expect(SlurmCommandBuilder.partitionsCommand == "sinfo -h -o \"%P\"")
        #expect(SlurmCommandBuilder.tmuxCheckCommand == "which tmux")
    }

    @Test
    func jsonParserParsesJobs() throws {
        let json = """
        {
          "jobs": [
            {
              "job_id": 12345,
              "name": "sim",
              "partition": "gpu",
              "job_state": ["RUNNING"],
              "node_count": 2,
              "cpus": 16,
              "time": { "used": 3600, "limit": 7200 },
              "state_reason": "None"
            }
          ]
        }
        """

        let parser = JSONSlurmParser()
        let jobs = try parser.parseJobs(json, profileId: UUID())
        #expect(jobs.count == 1)
        #expect(jobs[0].state == .running)
        #expect(jobs[0].timeUsed == 3600)
        #expect(jobs[0].timeLimit == 7200)
    }

    @Test
    func jsonParserComputesRunningElapsedFromStartTimeWhenElapsedMissing() throws {
        let now = Int(Date().timeIntervalSince1970)
        let start = now - 180

        let json = """
        {
          "jobs": [
            {
              "job_id": 3001,
              "name": "elapsed-fallback",
              "partition": "gpu",
              "job_state": ["RUNNING"],
              "cpus": 4,
              "start_time": { "set": true, "infinite": false, "number": \(start) },
              "time_limit": { "set": true, "infinite": false, "number": 600 }
            }
          ]
        }
        """

        let parser = JSONSlurmParser()
        let jobs = try parser.parseJobs(json, profileId: UUID())
        #expect(jobs.count == 1)

        let used = jobs[0].timeUsed
        #expect(used >= 120)
        #expect(used <= 240)
        #expect(jobs[0].timeLimit == 36_000)
    }

    @Test
    func jsonParserParsesNodeMemoryGpuAndWorkingDirectoryFields() throws {
        let json = """
        {
          "jobs": [
            {
              "job_id": 4001,
              "name": "rich-fields",
              "partition": "gpu",
              "job_state": ["RUNNING"],
              "node_count": { "set": true, "infinite": false, "number": 1 },
              "nodes": "node123",
              "cpus": { "set": true, "infinite": false, "number": 2 },
              "start_time": { "set": true, "infinite": false, "number": 1772017407 },
              "time_limit": { "set": true, "infinite": false, "number": 600 },
              "state_reason": "None",
              "current_working_directory": "/tmp/run",
              "memory_per_cpu": { "set": true, "infinite": false, "number": 6000 },
              "tres_alloc_str": "cpu=2,mem=12000M,node=1,gres/gpu=1"
            },
            {
              "job_id": 4002,
              "name": "pending",
              "partition": "gpu",
              "job_state": ["PENDING"],
              "node_count": { "set": true, "infinite": false, "number": 1 },
              "cpus": { "set": true, "infinite": false, "number": 2 },
              "state_reason": "Resources"
            }
          ]
        }
        """

        let parser = JSONSlurmParser()
        let jobs = try parser.parseJobs(json, profileId: UUID())

        let running = jobs.first(where: { $0.id == "4001" })
        #expect(running?.nodeList == "node123")
        #expect(running?.memoryRequestedMB == 12000)
        #expect(running?.gpuCount == 1)
        #expect(running?.workingDirectory == "/tmp/run")
        #expect(running?.pendingReason == nil)
        #expect(running?.timeLimit == 36_000)

        let pending = jobs.first(where: { $0.id == "4002" })
        #expect(pending?.pendingReason == "Resources")
    }

    @Test
    func jsonParserParsesJobDurationsFromSlurmNumberAndShortTimeFormats() throws {
        let json = """
        {
          "jobs": [
            {
              "job_id": 2001,
              "name": "num-shape",
              "partition": "gpu",
              "job_state": ["RUNNING"],
              "cpus": 4,
              "time": {
                "used": { "set": true, "infinite": false, "number": 3661 },
                "limit": { "set": true, "infinite": false, "number": 7200 }
              }
            },
            {
              "job_id": 2002,
              "name": "short-time",
              "partition": "gpu",
              "job_state": ["RUNNING"],
              "cpus": 2,
              "time": {
                "used": "04:12",
                "limit": "08:00:00"
              }
            }
          ]
        }
        """

        let parser = JSONSlurmParser()
        let jobs = try parser.parseJobs(json, profileId: UUID())

        #expect(jobs.count == 2)

        let first = jobs.first(where: { $0.id == "2001" })
        #expect(first?.timeUsed == 3661)
        #expect(first?.timeLimit == 7200)

        let second = jobs.first(where: { $0.id == "2002" })
        #expect(second?.timeUsed == 252)
        #expect(second?.timeLimit == 28800)
    }

    @Test
    func jsonParserAggregatesArrayProgressFromSampleShape() throws {
        let json = """
        {
          "jobs": [
            {
              "job_id": 226873,
              "name": "ag4_nenepo_job",
              "partition": "gpu5x,gpu6x",
              "job_state": ["PENDING"],
              "node_count": 1,
              "cpus": 2,
              "time": { "used": 0, "limit": 600 },
              "state_reason": "Resources",
              "array_job_id": { "set": true, "infinite": false, "number": 226873 },
              "array_task_id": { "set": false, "infinite": false, "number": 0 },
              "array_task_string": "4-7"
            },
            {
              "job_id": 226874,
              "name": "ag4_nenepo_job",
              "partition": "gpu5x",
              "job_state": ["RUNNING"],
              "node_count": 1,
              "cpus": 2,
              "time": { "used": 20, "limit": 600 },
              "state_reason": "None",
              "array_job_id": { "set": true, "infinite": false, "number": 226873 },
              "array_task_id": { "set": true, "infinite": false, "number": 4 }
            },
            {
              "job_id": 226875,
              "name": "ag4_nenepo_job",
              "partition": "gpu5x",
              "job_state": ["RUNNING"],
              "node_count": 1,
              "cpus": 2,
              "time": { "used": 15, "limit": 600 },
              "state_reason": "None",
              "array_job_id": { "set": true, "infinite": false, "number": 226873 },
              "array_task_id": { "set": true, "infinite": false, "number": 5 }
            }
          ]
        }
        """

        let parser = JSONSlurmParser()
        let jobs = try parser.parseJobs(json, profileId: UUID())

        #expect(jobs.count == 3)

        let parent = jobs.first(where: { $0.id == "226873" })
        #expect(parent != nil)
        #expect(parent?.isArray == true)
        #expect(parent?.arrayParentID == "226873")
        #expect(parent?.arrayTasksTotal == 4)
        #expect(parent?.arrayTasksDone == 0)

        let child = jobs.first(where: { $0.id == "226874" })
        #expect(child?.isArray == false)
        #expect(child?.arrayParentID == "226873")
    }

    @Test
    func jsonParserCountsNonZeroBasedArrayRangesWithoutInflation() throws {
        let json = """
        {
          "jobs": [
            {
              "job_id": 226873,
              "name": "ag4_nenepo_job",
              "partition": "gpu5x,gpu6x",
              "job_state": ["PENDING"],
              "node_count": 1,
              "cpus": 2,
              "time": { "used": 0, "limit": 600 },
              "state_reason": "Resources",
              "array_job_id": { "set": true, "infinite": false, "number": 226873 },
              "array_task_id": { "set": false, "infinite": false, "number": 0 },
              "array_task_string": "6-7"
            },
            {
              "job_id": 226874,
              "name": "ag4_nenepo_job",
              "partition": "gpu5x",
              "job_state": ["RUNNING"],
              "node_count": 1,
              "cpus": 2,
              "time": { "used": 20, "limit": 600 },
              "state_reason": "None",
              "array_job_id": { "set": true, "infinite": false, "number": 226873 },
              "array_task_id": { "set": true, "infinite": false, "number": 4 }
            },
            {
              "job_id": 226875,
              "name": "ag4_nenepo_job",
              "partition": "gpu5x",
              "job_state": ["RUNNING"],
              "node_count": 1,
              "cpus": 2,
              "time": { "used": 15, "limit": 600 },
              "state_reason": "None",
              "array_job_id": { "set": true, "infinite": false, "number": 226873 },
              "array_task_id": { "set": true, "infinite": false, "number": 5 }
            }
          ]
        }
        """

        let parser = JSONSlurmParser()
        let jobs = try parser.parseJobs(json, profileId: UUID())

        let parent = jobs.first(where: { $0.id == "226873" })
        #expect(parent?.arrayTasksTotal == 4)
        #expect(parent?.arrayTasksDone == 0)
    }

    @Test
    func jsonParserTreatsSingleNonArrayJobsAsRegularJobs() throws {
        let json = """
        {
          "jobs": [
            {
              "job_id": 748291,
              "name": "sim_ag4_wigner",
              "partition": "gpu5x",
              "job_state": ["RUNNING"],
              "node_count": 1,
              "cpus": 32,
              "time": { "used": "04:12:00", "limit": "06:00:00" },
              "array_job_id": { "set": true, "infinite": false, "number": 748291 },
              "array_task_id": { "set": false, "infinite": false, "number": 4294967294 },
              "array": { "task_count": 1, "task_finished": 0 }
            }
          ]
        }
        """

        let parser = JSONSlurmParser()
        let jobs = try parser.parseJobs(json, profileId: UUID())

        #expect(jobs.count == 1)
        #expect(jobs[0].isArray == false)
        #expect(jobs[0].arrayParentID == nil)
        #expect(jobs[0].arrayTaskID == nil)
        #expect(jobs[0].arrayTasksTotal == 0)
        #expect(jobs[0].state == .running)
        #expect(jobs[0].timeUsed == 15_120)
        #expect(jobs[0].timeLimit == 21_600)
    }

    @Test
    func parserFairshareAndClusterLoad() throws {
        let fairshareJSON = """
        {
          "shares": {
            "shares": [
              {
                "user": "alice",
                "fairshare": { "factor": 0.42 }
              }
            ]
          }
        }
        """

        let loadJSON = """
        {
          "nodes": [
            { "cpus": { "total": 64, "allocated": 48 } },
            { "cpus": { "total": 32, "allocated": 0 } }
          ]
        }
        """

        let parser = JSONSlurmParser()
        let fairshare = parser.parseFairshare(fairshareJSON)
        #expect(fairshare == 0.42)

        let load = try parser.parseClusterLoad(loadJSON, profileId: UUID())
        #expect(load.totalCPUs == 96)
        #expect(load.allocatedCPUs == 48)
        #expect(load.totalNodes == 2)
        #expect(load.allocatedNodes == 1)
    }

    @Test
    func parserClusterLoadSupportsSinfoRowsShape() throws {
        let sinfoJSON = """
        {
          "sinfo": [
            {
              "nodes": { "allocated": 0, "total": 1 },
              "cpus": { "allocated": 0, "total": 40 }
            },
            {
              "nodes": { "allocated": 1, "total": 2 },
              "cpus": { "allocated": 64, "total": 128 }
            }
          ]
        }
        """

        let parser = JSONSlurmParser()
        let load = try parser.parseClusterLoad(sinfoJSON, profileId: UUID())
        #expect(load.totalCPUs == 168)
        #expect(load.allocatedCPUs == 64)
        #expect(load.totalNodes == 3)
        #expect(load.allocatedNodes == 1)
    }

    @Test
    func nodeInventoryParserSupportsSinfoShape() throws {
        let json = """
        {
          "sinfo": [
            {
              "node": { "state": ["IDLE"] },
              "nodes": { "nodes": ["gpu50"], "total": 1, "allocated": 0 },
              "cpus": { "allocated": 0, "minimum": 64, "maximum": 64, "total": 64 },
              "memory": { "minimum": 512000, "maximum": 512000 },
              "features": { "active": "zen4" },
              "gres": { "total": "gpu:4" },
              "partition": {
                "name": "gpu5x",
                "nodes": { "configured": "gpu[50-55]" },
                "cpus": { "total": 384 },
                "defaults": {
                  "partition_memory_per_cpu": { "number": 1024 },
                  "time": { "number": 20160 }
                },
                "maximums": { "time": { "number": 144000 } },
                "partition": { "state": ["UP"] },
                "tres": { "configured": "cpu=384" }
              }
            }
          ]
        }
        """

        let inventory = try NodeInventoryParser.parse(output: json)
        #expect(inventory.nodes.count == 1)
        #expect(inventory.nodes.first?.name == "gpu50")
        #expect(inventory.nodes.first?.memoryMB == 512000)
        #expect(inventory.nodes.first?.totalCPUs == 64)
        #expect(inventory.nodes.first?.partitions == ["gpu5x"])

        #expect(inventory.partitions.count == 1)
        #expect(inventory.partitions.first?.name == "gpu5x")
        #expect(inventory.partitions.first?.defaultMemoryPerCPUMB == 1024)
    }

    @Test
    func nodeInventoryParserCapturesGresUsageWhenAvailable() throws {
        let json = """
        {
          "nodes": [
            {
              "name": "gpu-node-longname-001",
              "state": ["MIXED"],
              "cpus": { "total": 64, "allocated": 32 },
              "real_memory": 512000,
              "gres": { "total": "gpu:a100:8", "used": "gpu:a100:3" },
              "partitions": ["gpu"]
            }
          ]
        }
        """

        let inventory = try NodeInventoryParser.parse(output: json)
        #expect(inventory.nodes.count == 1)
        #expect(inventory.nodes.first?.gres == "gpu:a100:8")
        #expect(inventory.nodes.first?.gresUsed == "gpu:a100:3")
    }

    @Test
    func clusterOverviewBuilderAggregatesNodeAndPartitionCounts() throws {
        let json = """
        {
          "sinfo": [
            {
              "node": { "state": ["IDLE"] },
              "nodes": { "nodes": ["gpu50"], "total": 1, "allocated": 0 },
              "cpus": { "allocated": 0, "minimum": 64, "maximum": 64, "total": 64 },
              "partition": { "name": "gpu5x" }
            },
            {
              "node": { "state": ["DOWN"] },
              "nodes": { "nodes": ["gpu51"], "total": 1, "allocated": 0 },
              "cpus": { "allocated": 0, "minimum": 64, "maximum": 64, "total": 64 },
              "partition": { "name": "gpu5x" }
            },
            {
              "node": { "state": ["FAIL"] },
              "nodes": { "nodes": ["gpu52"], "total": 1, "allocated": 0 },
              "cpus": { "allocated": 0, "minimum": 64, "maximum": 64, "total": 64 },
              "partition": { "name": "gpu6x" }
            },
            {
              "node": { "state": ["ALLOCATED", "RESERVED"] },
              "nodes": { "nodes": ["gpu53"], "total": 1, "allocated": 1 },
              "cpus": { "allocated": 64, "minimum": 64, "maximum": 64, "total": 64 },
              "partition": { "name": "gpu6x" }
            },
            {
              "node": { "state": ["DRAINING"] },
              "nodes": { "nodes": ["gpu54"], "total": 1, "allocated": 0 },
              "cpus": { "allocated": 0, "minimum": 64, "maximum": 64, "total": 64 },
              "partition": { "name": "gpu6x" }
            }
          ]
        }
        """

        let inventory = try NodeInventoryParser.parse(output: json)
        let overview = ClusterOverviewBuilder.build(profileId: UUID(), inventory: inventory)

        #expect(overview.totalNodes == 5)
        #expect(overview.partitionCount == 2)
        #expect(overview.idleNodes == 1)
        #expect(overview.downNodes == 1)
        #expect(overview.failedNodes == 1)
        #expect(overview.drainingNodes == 1)
        #expect(overview.reservedNodes == 1)
        #expect(overview.allocatedNodes == 1)
        #expect(overview.downNodeNames == ["gpu51"])
        #expect(overview.failedNodeNames == ["gpu52"])
        #expect(overview.reservedNodeNames == ["gpu53"])
        #expect(overview.drainingNodeNames == ["gpu54"])
    }

    @Test
    func jsonParserJobHistorySkipsStepEntries() throws {
        let json = """
        {
          "jobs": [
            {
              "job_id": "12345",
              "name": "main",
              "state": ["COMPLETED"],
              "elapsed": "01:00:00",
              "timelimit": "UNLIMITED",
              "cpu_time": "02:00:00",
              "cpus_req": 2,
              "exit_code": "0:0"
            },
            {
              "job_id": "12345.batch",
              "name": "batch-step",
              "state": ["COMPLETED"],
              "elapsed": "00:59:00",
              "cpu_time": "01:58:00",
              "cpus_req": 2
            }
          ]
        }
        """

        let parser = JSONSlurmParser()
        let history = try parser.parseJobHistory(json, profileId: UUID())
        #expect(history.count == 1)
        #expect(history.first?.id == "12345")
        #expect(history.first?.timeLimit == nil)
    }
}

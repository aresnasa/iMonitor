//
//  ProcessEntity.swift
//  iMonitor
//
//  Created by f.zou on 2021/5/23.
//
import Cocoa
import Foundation

struct ProcessEntity: Identifiable {
    var id = UUID()

    public var pid: Int
    public var name: String
    public var inBytes: Int
    public var outBytes: Int
    public var cpuUsage: Double
    public var memoryUsed: UInt64
    public var icon: NSImage?

    public init(pid: Int, name: String, inBytes: Int, outBytes: Int, cpuUsage: Double = 0, memoryUsed: UInt64 = 0) {
        self.pid = pid
        self.name = name
        self.inBytes = inBytes
        self.outBytes = outBytes
        self.cpuUsage = cpuUsage
        self.memoryUsed = memoryUsed
        self.icon = nil
    }
}

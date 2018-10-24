#!/usr/bin/env python
# coding=utf-8

import heapq
import struct
import socket

class ImpactHeap:
    def __init__(self, impact_factor):
        self._heap = []
        self.impact_factor = impact_factor

    def push(self, ip_addr, total_matched, last_matched):
        item = (-1 * impact_factor(total_matched, last_matched), ip_addr)
        heapq.heappush(self._heap, item)
        return item

    def pop(self):
        return heapq.heappop(self._heap)

class IP2HC:
    def __init__(self, impact_factor_function):
        # Init the Impact Heap of the IP2HC
        self.impact_heap = ImpactHeap(impact_factor_function)
        # Init each column of the IP2HC table
        self.hc_value = [-1 for ip_addr in range(2^32)]
        self.total_matched = [0 for ip_addr in range(2^32)]
        self.last_matched = [0 for ip_addr in range(2^32)]
        self.cached = [0 for ip_addr in range(2^32)]
        self.heap_pointer = [
            self.impact_heap.push(ip_addr, 0, 0) for ip_addr in range(2^32)
        ]

    def read(self, ip_addr):
        if type(ip_addr) == str:
            ip_addr = struct.unpack('!I', socket.inet_aton(ip_addr))[0]
        return self.hc_value[ip_addr]



# Test Plan

## Functional baseline
1. Verify physical links and addresses.
2. Start FFmpeg MPEG-TS multicast stream.
3. Start one VLC client and capture real IGMPv2 Report.
4. Verify DUT upstream IGMP Proxy signaling.
5. Verify video/data reception.
6. Verify DUT multicast state and hardware-flow programming.
7. Stop client and verify Leave/cleanup.

## Multi-client
1. Start client 1 and client 2 on the same group.
2. Verify both receive the stream.
3. Stop client 1.
4. Verify client 2 continues without interruption.
5. Stop client 2 and verify final flow deletion.

## Scale and compliance
- 32 simultaneous groups.
- IGMP source IP/MAC validation.
- DS field `0x88` and DF=1 verification.
- Group-Specific Query behavior.
- 100 ms Join/Leave churn.
- Join-to-first-payload latency <= 10 ms.
- 250 Group-Specific Queries/s with a dedicated traffic generator.
- 12 groups, 1200-byte traffic and long-duration loss qualification on a two-host or hardware-generator setup.

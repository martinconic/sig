//! to use the fuzzer run the following command:
//!     ./zig-out/bin/fuzz <seed> <num_messages> ?<entrypoint>
//! to stop the fuzzer write any input to stdin and press enter
const std = @import("std");
const sig = @import("../sig.zig");

const bincode = sig.bincode;

const EndPoint = @import("zig-network").EndPoint;
const GossipService = sig.gossip.service.GossipService;
const ChunkType = sig.gossip.service.ChunkType;
const LegacyContactInfo = sig.gossip.data.LegacyContactInfo;
const SignedGossipData = sig.gossip.data.SignedGossipData;
const ContactInfo = sig.gossip.data.ContactInfo;
const GossipMessage = sig.gossip.message.GossipMessage;
const GossipPullFilterSet = sig.gossip.pull_request.GossipPullFilterSet;
const GossipPullFilter = sig.gossip.pull_request.GossipPullFilter;
const Ping = sig.gossip.ping_pong.Ping;
const Pong = sig.gossip.ping_pong.Pong;
const SocketAddr = sig.net.net.SocketAddr;
const Pubkey = sig.core.pubkey.Pubkey;
const Bloom = sig.bloom.bloom.Bloom;
const Packet = sig.net.packet.Packet;
const Hash = sig.core.hash.Hash;
const KeyPair = std.crypto.sign.Ed25519.KeyPair;
const Atomic = std.atomic.Value;
const Duration = sig.time.Duration;

const gossipDataToPackets = sig.gossip.service.gossipDataToPackets;

const PACKET_DATA_SIZE = sig.net.packet.PACKET_DATA_SIZE;
const SLEEP_TIME = Duration.zero();
// const SLEEP_TIME = Duration.fromMillis(10);
// const SLEEP_TIME = Duration.fromSecs(10);

pub fn serializeToPacket(d: anytype, to_addr: EndPoint) !Packet {
    var packet_buf: [PACKET_DATA_SIZE]u8 = undefined;
    const msg_slice = try bincode.writeToSlice(&packet_buf, d, bincode.Params{});
    const packet = Packet.init(to_addr, packet_buf, msg_slice.len);
    return packet;
}

pub fn randomPing(random: std.rand.Random, keypair: *const KeyPair) !GossipMessage {
    const ping = GossipMessage{
        .PingMessage = try Ping.initRandom(random, keypair),
    };
    return ping;
}

pub fn randomPingPacket(random: std.rand.Random, keypair: *const KeyPair, to_addr: EndPoint) !Packet {
    const ping = try randomPing(random, keypair);
    const packet = try serializeToPacket(ping, to_addr);
    return packet;
}

pub fn randomPong(random: std.rand.Random, keypair: *const KeyPair) !GossipMessage {
    return .{ .PongMessage = try Pong.initRandom(random, keypair) };
}

pub fn randomPongPacket(random: std.rand.Random, keypair: *const KeyPair, to_addr: EndPoint) !Packet {
    const pong = try randomPong(random, keypair);
    const packet = try serializeToPacket(pong, to_addr);
    return packet;
}

pub fn randomSignedGossipData(random: std.rand.Random, must_pass_sign_verification: bool) !SignedGossipData {
    const keypair = try KeyPair.create(null);
    const pubkey = Pubkey.fromPublicKey(&keypair.public_key);
    const lci = LegacyContactInfo.default(if (must_pass_sign_verification) pubkey else Pubkey.initRandom(random));
    return SignedGossipData.initSigned(&keypair, .{ .LegacyContactInfo = lci });
}

pub fn randomPushMessage(
    allocator: std.mem.Allocator,
    random: std.rand.Random,
    keypair: *const KeyPair,
    to_addr: EndPoint,
) !std.ArrayList(Packet) {
    const size: comptime_int = 5;
    var values: [size]SignedGossipData = undefined;
    const should_pass_sig_verification = random.boolean();
    for (0..size) |i| {
        const value = try randomSignedGossipData(random, should_pass_sig_verification);
        values[i] = value;
    }

    const packets = try gossipDataToPackets(
        allocator,
        &Pubkey.fromPublicKey(&keypair.public_key),
        &values,
        &to_addr,
        ChunkType.PushMessage,
    );
    return packets;
}

pub fn randomPullResponse(random: std.rand.Random, keypair: *const KeyPair, to_addr: EndPoint) !std.ArrayList(Packet) {
    const size: comptime_int = 5;
    var values: [size]SignedGossipData = undefined;
    const should_pass_sig_verification = random.boolean();
    for (0..size) |i| {
        const value = try randomSignedGossipData(random, should_pass_sig_verification);
        values[i] = value;
    }

    const allocator = std.heap.c_allocator;
    const packets = try gossipDataToPackets(
        allocator,
        &Pubkey.fromPublicKey(&keypair.public_key),
        &values,
        &to_addr,
        ChunkType.PullResponse,
    );
    return packets;
}

/// note the contact info must have responded to a ping
/// for a valid pull response to be generated
pub fn randomPullRequest(
    allocator: std.mem.Allocator,
    contact_info: LegacyContactInfo,
    random: std.rand.Random,
    keypair: *const KeyPair,
    to_addr: EndPoint,
) !Packet {
    const value = SignedGossipData.initSigned(keypair, .{ .LegacyContactInfo = contact_info });
    return randomPullRequestWithContactInfo(allocator, random, to_addr, value);
}

pub fn randomPullRequestWithContactInfo(
    allocator: std.mem.Allocator,
    random: std.rand.Random,
    to_addr: EndPoint,
    contact_info: SignedGossipData,
) !Packet {
    const N_FILTER_BITS = random.intRangeAtMost(u6, 1, 10);

    // only consider the first bit so we know well get matches
    var bloom = try Bloom.initRandom(allocator, random, 100, 0.1, N_FILTER_BITS);
    defer bloom.deinit();

    var filter = GossipPullFilter{
        .filter = bloom,
        .mask = (~@as(usize, 0)) >> N_FILTER_BITS,
        .mask_bits = N_FILTER_BITS,
    };

    // const invalid_filter = rng.boolean();
    const invalid_filter = false;
    if (invalid_filter) {
        filter.mask = (~@as(usize, 0)) >> random.intRangeAtMost(u6, 1, 10);
        filter.mask_bits = random.intRangeAtMost(u6, 1, 10);

        // add more random hashes
        for (0..5) |_| {
            const rand_value = try randomSignedGossipData(random, true);
            var buf: [PACKET_DATA_SIZE]u8 = undefined;
            const bytes = try bincode.writeToSlice(&buf, rand_value, bincode.Params.standard);
            const value_hash = Hash.generateSha256Hash(bytes);
            filter.filter.add(&value_hash.data);
        }
    } else {
        // add some valid hashes
        var filter_set = try GossipPullFilterSet.initTest(allocator, random, filter.mask_bits);

        for (0..5) |_| {
            const rand_value = try randomSignedGossipData(random, true);
            var buf: [PACKET_DATA_SIZE]u8 = undefined;
            const bytes = try bincode.writeToSlice(&buf, rand_value, bincode.Params.standard);
            const value_hash = Hash.generateSha256Hash(bytes);
            filter_set.add(&value_hash);
        }

        var filters = try filter_set.consumeForGossipPullFilters(allocator, random, 1);
        filter.filter = filters.items[0].filter;
        filter.mask = filters.items[0].mask;
        filter.mask_bits = filters.items[0].mask_bits;

        for (filters.items[1..]) |*filter_i| {
            filter_i.filter.deinit();
        }
        filters.deinit();
    }

    // serialize and send as packet
    const msg = GossipMessage{ .PullRequest = .{ filter, contact_info } };
    var packet_buf: [PACKET_DATA_SIZE]u8 = undefined;
    const msg_slice = try bincode.writeToSlice(&packet_buf, msg, bincode.Params{});
    const packet = Packet.init(to_addr, packet_buf, msg_slice.len);

    if (!invalid_filter) {
        filter.filter.deinit();
    }

    return packet;
}

pub fn waitForExit(exit: *Atomic(bool)) void {
    const reader = std.io.getStdOut().reader();
    var buf: [1]u8 = undefined;
    _ = reader.read(&buf) catch unreachable;

    exit.store(true, .release);
}

pub fn run(seed: u64, args: *std.process.ArgIterator) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator(); // use std.testing.allocator to detect leaks
    defer _ = gpa.deinit();

    var prng = std.rand.DefaultPrng.init(seed);

    // parse cli args to define where to send packets
    const maybe_max_messages_string = args.next();
    const maybe_entrypoint = args.next();

    const to_entrypoint, const fuzz_sig = blk: {
        if (maybe_entrypoint) |entrypoint| {
            const addr = SocketAddr.parse(entrypoint) catch @panic("invalid entrypoint");
            break :blk .{ addr.toEndpoint(), false };
        } else {
            // default to localhost (wont actually send anything)
            break :blk .{ try EndPoint.parse("127.0.0.1:8001"), true };
        }
    };

    const maybe_max_messages = blk: {
        if (maybe_max_messages_string) |max_messages_str| {
            break :blk try std.fmt.parseInt(usize, max_messages_str, 10);
        } else {
            break :blk null;
        }
    };

    // setup sending socket
    var fuzz_keypair = try KeyPair.create(null);
    const fuzz_address = SocketAddr.initIpv4(.{ 127, 0, 0, 1 }, 9998);
    const fuzz_pubkey = Pubkey.fromPublicKey(&fuzz_keypair.public_key);
    var fuzz_contact_info = ContactInfo.init(allocator, fuzz_pubkey, 0, 19);
    try fuzz_contact_info.setSocket(.gossip, fuzz_address);

    var counter = Atomic(usize).init(0);

    // find leaks
    var gpa_gossip_alloc = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
    }){};
    defer _ = gpa_gossip_alloc.deinit();
    const gossip_alloc = gpa_gossip_alloc.allocator();

    var gossip_client, const packet_channel, var handle = blk: {
        if (fuzz_sig) {
            // this is who we blast messages at
            var client_keypair = try KeyPair.create(null);
            const client_address = SocketAddr.initIpv4(.{ 127, 0, 0, 1 }, 9988);
            const client_pubkey = Pubkey.fromPublicKey(&client_keypair.public_key);
            var client_contact_info = ContactInfo.init(allocator, client_pubkey, 0, 19);
            try client_contact_info.setSocket(.gossip, client_address);
            const gossip_service_client = try GossipService.create(
                gossip_alloc,
                gossip_alloc,
                client_contact_info,
                client_keypair,
                null, // we will only recv packets
                &counter,
                .noop, // no logs
            );

            const client_handle = try std.Thread.spawn(.{}, GossipService.run, .{
                gossip_service_client, .{
                    .spy_node = true,
                    .dump = false,
                },
            });
            // this is used to respond to pings
            const gossip_service_fuzzer = try GossipService.create(
                allocator,
                allocator,
                fuzz_contact_info,
                fuzz_keypair,
                (&SocketAddr.fromEndpoint(&to_entrypoint))[0..1], // we only want to communicate with one node
                &counter,
                .noop, // no logs
            );

            // this is mainly used to just send packets through the fuzzer
            // but we also want to respond to pings so we need to run the full gossip service
            const fuzz_handle = try std.Thread.spawn(.{}, GossipService.run, .{
                gossip_service_fuzzer, .{
                    .spy_node = true,
                    .dump = false,
                },
            });
            fuzz_handle.detach();

            break :blk .{ gossip_service_client, gossip_service_client.packet_incoming_channel, client_handle };
        } else {
            const gossip_service_fuzzer = try GossipService.create(
                allocator,
                allocator,
                fuzz_contact_info,
                fuzz_keypair,
                (&SocketAddr.fromEndpoint(&to_entrypoint))[0..1], // we only want to communicate with one node
                &counter,
                .noop, // no logs
            );

            // this is mainly used to just send packets through the fuzzer
            // but we also want to respond to pings so we need to run the full gossip service
            const fuzz_handle = try std.Thread.spawn(.{}, GossipService.run, .{
                gossip_service_fuzzer, .{
                    .spy_node = true,
                    .dump = false,
                },
            });

            break :blk .{ gossip_service_fuzzer, gossip_service_fuzzer.packet_outgoing_channel, fuzz_handle };
        }
    };

    // NOTE: this is useful when we want to run for an inf amount of time and want to
    // early exit at some point without killing the process
    var fuzzing_loop_exit = Atomic(bool).init(false);
    // wait for any keyboard input to exit early
    var exit_handle = try std.Thread.spawn(.{}, waitForExit, .{&fuzzing_loop_exit});
    exit_handle.detach();

    // start fuzzing
    try fuzz(
        allocator,
        &fuzzing_loop_exit,
        maybe_max_messages,
        prng.random(),
        &fuzz_keypair,
        LegacyContactInfo.fromContactInfo(&fuzz_contact_info),
        to_entrypoint,
        packet_channel,
    );

    // cleanup
    std.debug.print("\t=> shutting down...\n", .{});
    counter.store(1, .release);
    handle.join();

    gossip_client.shutdown();
    gossip_client.deinit();
    std.debug.print("\t=> done.\n", .{});
}

pub fn fuzz(
    allocator: std.mem.Allocator,
    loop_exit: *Atomic(bool),
    maybe_max_messages: ?usize,
    random: std.Random,
    keypair: *const KeyPair,
    contact_info: LegacyContactInfo,
    to_endpoint: EndPoint,
    outgoing_channel: *sig.sync.Channel(Packet),
) !void {
    var msg_count: usize = 0;

    while (!loop_exit.load(.acquire)) {
        if (maybe_max_messages) |max_messages| {
            if (msg_count >= max_messages) {
                std.debug.print("reached max messages: {d}\n", .{msg_count});
                break;
            }
        }

        const action = random.enumValue(enum {
            ping,
            pong,
            push,
            pull_request,
            pull_response,
        });
        const packet = switch (action) {
            .ping => blk: {
                // send ping message
                const packet = randomPingPacket(random, keypair, to_endpoint);
                break :blk packet;
            },
            .pong => blk: {
                // send pong message
                const packet = randomPongPacket(random, keypair, to_endpoint);
                break :blk packet;
            },
            .push => blk: {
                // send push message
                const packets = randomPushMessage(allocator, random, keypair, to_endpoint) catch |err| {
                    std.debug.print("ERROR: {s}\n", .{@errorName(err)});
                    continue;
                };
                defer packets.deinit();

                const packet = packets.items[0];
                break :blk packet;
            },
            .pull_request => blk: {
                // send pull response
                const packets = randomPullResponse(random, keypair, to_endpoint) catch |err| {
                    std.debug.print("ERROR: {s}\n", .{@errorName(err)});
                    continue;
                };
                defer packets.deinit();

                const packet = packets.items[0];
                break :blk packet;
            },
            .pull_response => blk: {
                // send pull request
                const packet = randomPullRequest(
                    allocator,
                    contact_info,
                    random,
                    keypair,
                    to_endpoint,
                );
                break :blk packet;
            },
        } catch |err| {
            std.debug.print("ERROR: {s}\n", .{@errorName(err)});
            continue;
        };

        // batch it
        msg_count +|= 1;

        // send it
        try outgoing_channel.send(packet);

        const send_duplicate = random.boolean();
        if (send_duplicate) {
            msg_count +|= 1;
            try outgoing_channel.send(packet);
        }

        std.time.sleep(SLEEP_TIME.asNanos());

        if (msg_count % 1000 == 0) {
            std.debug.print("{d} messages sent\n", .{msg_count});
        }
    }
}

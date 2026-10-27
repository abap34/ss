#include "perfetto.h"
#include <atomic>
#include <cstdio>
#include <memory>
#include <mutex>
#include <vector>

PERFETTO_DEFINE_CATEGORIES(perfetto::Category("ss"));
PERFETTO_TRACK_EVENT_STATIC_STORAGE();

namespace {
struct Recording {
    std::unique_ptr<perfetto::TracingSession> session;
    FILE* output;
    bool stopped = false;
};
perfetto::Track operation_track(uint64_t id) {
    return perfetto::Track(id | (uint64_t{1} << 63), perfetto::ProcessTrack::Current());
}

// Completed measurements arrive inside-out. Separate overlapping intervals so
// equal timestamps cannot exchange their BEGIN/END partners during sorting.
perfetto::Track completed_track(uint64_t start, uint64_t end) {
    struct Lane { uint64_t end; perfetto::Track track; };
    struct Lanes {
        std::vector<Lane> values;
        ~Lanes() {
            for (const auto& lane : values)
                perfetto::TrackEvent::EraseTrackDescriptor(lane.track);
        }
    };
    static std::atomic<uint64_t> next_id{0};
    thread_local Lanes lanes;
    for (auto& lane : lanes.values) {
        if (lane.end <= start) {
            lane.end = end;
            return lane.track;
        }
    }
    const auto parent = perfetto::ThreadTrack::Current();
    const auto id = uint64_t{0x53535f0000000000} + next_id.fetch_add(1, std::memory_order_relaxed);
    // Track ids are XORed with the parent uuid. Cancel that contribution so
    // adjacent thread ids and lane numbers cannot produce the same uuid.
    const auto track = perfetto::Track(id ^ parent.uuid ^ perfetto::ProcessTrack::Current().uuid, parent);
    auto descriptor = track.Serialize();
    descriptor.set_name("Measurements " + std::to_string(lanes.values.size() + 1));
    perfetto::TrackEvent::SetTrackDescriptor(track, descriptor);
    lanes.values.push_back({end, track});
    return track;
}
}

extern "C" void* ss_profile_start(const char* path, uint32_t buffer_kb) {
    static std::once_flag initialized;
    std::call_once(initialized, [] {
        perfetto::TracingInitArgs args;
        args.backends = perfetto::kInProcessBackend;
        args.log_message_callback = [](perfetto::LogMessageCallbackArgs message) {
            if (message.level >= perfetto::base::kLogError)
                std::fprintf(stderr, "[profiling] %s\n", message.message);
        };
        perfetto::Tracing::Initialize(args);
        perfetto::TrackEvent::Register();
        // The SDK's default Linux descriptor includes argv. Register a minimal
        // process descriptor before any event can publish private input paths.
        const auto process = perfetto::ProcessTrack::Current();
        perfetto::protos::gen::TrackDescriptor descriptor;
        descriptor.set_uuid(process.uuid);
        descriptor.mutable_process()->set_pid(static_cast<int32_t>(process.pid));
        descriptor.mutable_process()->set_process_name("ss");
        perfetto::TrackEvent::SetTrackDescriptor(process, descriptor);
    });
    FILE* output = std::fopen(path, "wbx");
    if (!output) return nullptr;
    auto recording = std::make_unique<Recording>();
    recording->output = output;
    perfetto::TraceConfig config;
    auto* buffer = config.add_buffers();
    buffer->set_size_kb(buffer_kb);
    buffer->set_fill_policy(perfetto::protos::gen::TraceConfig::BufferConfig::DISCARD);
    auto* source = config.add_data_sources()->mutable_config();
    source->set_name("track_event");
    perfetto::protos::gen::TrackEventConfig events;
    events.add_disabled_categories("*");
    events.add_enabled_categories("ss");
    // Existing measurements report completed nested spans. Absolute timestamps
    // let the trace processor sort their original boundaries correctly.
    events.set_disable_incremental_timestamps(true);
    source->set_track_event_config_raw(events.SerializeAsString());
    recording->session = perfetto::Tracing::NewTrace();
    recording->session->Setup(config);
    recording->session->StartBlocking();
    return recording.release();
}

extern "C" int ss_profile_checkpoint(void* pointer, bool stop) {
    auto& recording = *static_cast<Recording*>(pointer);
    perfetto::TrackEvent::Flush();
    if (!recording.session->FlushBlocking(5000)) return 0;
    if (stop && !recording.stopped) {
        recording.session->StopBlocking();
        recording.stopped = true;
    }
    // Reading drains the SDK's bounded buffer. Append complete trace packets,
    // so checkpoints preserve earlier requests without a second event store.
    auto bytes = recording.session->ReadTraceBlocking();
    if (std::fwrite(bytes.data(), 1, bytes.size(), recording.output) != bytes.size()) return 0;
    return std::fflush(recording.output) == 0;
}

extern "C" void ss_profile_destroy(void* pointer) {
    auto* recording = static_cast<Recording*>(pointer);
    if (!recording->stopped) recording->session->StopBlocking();
    recording->session.reset();
    std::fclose(recording->output);
    delete recording;
}

extern "C" uint64_t ss_profile_now_ns() {
    return perfetto::TrackEvent::GetTraceTimeNs();
}

extern "C" void ss_profile_span(const char* category, size_t category_size,
                                 const char* name, size_t name_size,
                                 uint64_t start, uint64_t end, uint64_t operation) {
    const auto track = completed_track(start, end);
    TRACE_EVENT_BEGIN("ss", perfetto::DynamicString(name, name_size), track, start,
                      "component", perfetto::DynamicString(category, category_size), "operation", operation,
                      "thread", perfetto::ThreadTrack::Current().tid,
                      "duration_ns", end - start);
    TRACE_EVENT_END("ss", track, end);
}

extern "C" void ss_profile_counter(const char* name, size_t size, uint64_t value) {
    TRACE_COUNTER("ss", perfetto::CounterTrack(perfetto::DynamicString(name, size)), value);
}

extern "C" void ss_profile_task(uint64_t id, uint64_t parent, const char* name, size_t name_size,
                                 uint64_t revision, int64_t version, uint64_t request,
                                 bool queued) {
    const auto track = operation_track(id);
    auto descriptor = track.Serialize();
    descriptor.set_name(std::string(name, name_size));
    perfetto::TrackEvent::SetTrackDescriptor(track, descriptor);
    TRACE_EVENT_BEGIN("ss", perfetto::DynamicString(name, name_size), track,
                      "component", "operation", "operation", id, "parent", parent,
                      "revision", revision, "version", version, "request", request);
    if (queued) TRACE_EVENT_BEGIN("ss", "queue", track, "component", "queue", "operation", id);
}

extern "C" void ss_profile_enter(uint64_t id, bool queued) {
    const auto track = operation_track(id);
    if (queued) TRACE_EVENT_END("ss", track);
    TRACE_EVENT_BEGIN("ss", "execute", track, "component", "execution", "operation", id);
}

extern "C" void ss_profile_finish(uint64_t id, const char* outcome) {
    const auto track = operation_track(id);
    TRACE_EVENT_END("ss", track);
    TRACE_EVENT_END("ss", track, "outcome", perfetto::DynamicString(outcome));
    perfetto::TrackEvent::EraseTrackDescriptor(track);
}

extern "C" void ss_profile_cancel(uint64_t id) {
    TRACE_EVENT_INSTANT("ss", "cancel_requested", operation_track(id), "operation", id);
}

extern "C" void ss_profile_flush_thread() {
    perfetto::TrackEvent::Flush();
}

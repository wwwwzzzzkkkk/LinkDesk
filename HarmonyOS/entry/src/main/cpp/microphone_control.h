#pragma once
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <cstdint>
#include <cerrno>
#include <mutex>
#include <thread>

// The Mac owns the shared intent. Audio stays on the separate LDMI socket;
// a remote request never bypasses foreground/UI permission checks on the tablet.
class MicrophoneControl {
public:
    explicit MicrophoneControl(uint16_t port = 24834) : port_(port) {}
    ~MicrophoneControl() { Stop(); }
    void Start() {
        if (running_.exchange(true)) return;
        worker_ = std::thread([this] { Loop(); });
    }
    void Stop() {
        if (!running_.exchange(false)) return;
        wake_.notify_all();
        if (worker_.joinable()) worker_.join();
        std::lock_guard<std::mutex> lock(mutex_);
        desired_ = false; pending_ = -1; ++generation_;
    }
    void SetRequested(bool value) {
        std::lock_guard<std::mutex> lock(mutex_);
        desired_ = value; pending_ = value ? 1 : 0; ++generation_;
        wake_.notify_all();
    }
    bool Requested() const { return desired_.load(); }
private:
    const uint16_t port_;
    std::atomic<bool> running_{false}, desired_{false};
    std::thread worker_;
    std::mutex mutex_;
    std::condition_variable wake_;
    int pending_ = -1;
    uint64_t generation_ = 0;
    int Exchange(int request) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return -1;
        timeval timeout{0, 300000};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
#if defined(SO_NOSIGPIPE)
        int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        sockaddr_in address{}; address.sin_family = AF_INET;
        address.sin_port = htons(port_); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        int result = -1;
        if (connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0) {
            const char *command = request < 0 ? "LDMICGET" : request ? "LDMICON1" : "LDMICOFF";
            size_t sent = 0;
            while (sent < 8) {
                #if defined(MSG_NOSIGNAL)
                ssize_t count = send(fd, command + sent, 8 - sent, MSG_NOSIGNAL);
#else
                ssize_t count = send(fd, command + sent, 8 - sent, 0);
#endif
                if (count < 0 && errno == EINTR) continue;
                if (count <= 0) break;
                sent += count;
            }
            char reply = 0;
            if (sent == 8 && recv(fd, &reply, 1, 0) == 1 && (reply == '0' || reply == '1')) result = reply - '0';
        }
        close(fd); return result;
    }
    void Loop() {
        while (running_) {
            int request; uint64_t generation;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                request = pending_; generation = generation_;
            }
            int response = Exchange(request);
            std::unique_lock<std::mutex> lock(mutex_);
            // An in-flight GET must never undo a newer tap on the tablet.
            if (response >= 0 && generation == generation_) {
                desired_ = response == 1; pending_ = -1;
            }
            wake_.wait_for(lock, std::chrono::milliseconds(500), [this, generation] {
                return !running_ || generation != generation_;
            });
        }
        // Leaving the receiver/background never leaves the Mac input armed.
        Exchange(0);
    }
};

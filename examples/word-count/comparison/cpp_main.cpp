#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <functional>
#include <iostream>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

constexpr std::size_t chunk_size = 32 * 1024;
constexpr std::size_t batch_size = 4096;
constexpr std::size_t cycles = 32768;

struct TransparentHash {
    using is_transparent = void;
    std::size_t operator()(std::string_view value) const {
        return std::hash<std::string_view>{}(value);
    }
};

using Counts = std::unordered_map<std::string, std::uint64_t, TransparentHash, std::equal_to<>>;

bool separator(char byte) {
    return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n';
}

void add(Counts& counts, std::string_view word) {
    if (auto found = counts.find(word); found != counts.end()) {
        ++found->second;
    } else {
        counts.emplace(std::string(word), 1);
    }
}

bool words(const char* path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) return false;
    Counts counts;
    std::string carry;
    for (;;) {
        auto buffer = std::make_unique_for_overwrite<char[]>(chunk_size);
        file.read(buffer.get(), chunk_size);
        if (file.bad() || (file.fail() && !file.eof())) return false;
        const std::string_view chunk(buffer.get(), static_cast<std::size_t>(file.gcount()));
        if (chunk.empty()) {
            if (!carry.empty()) add(counts, carry);
            break;
        }
        std::size_t start = 0;
        for (std::size_t index = 0; index < chunk.size(); ++index) {
            if (!separator(chunk[index])) continue;
            const auto part = chunk.substr(start, index - start);
            if (!carry.empty()) {
                carry.append(part);
                add(counts, carry);
                carry.clear();
            } else if (!part.empty()) {
                add(counts, part);
            }
            start = index + 1;
        }
        carry.append(chunk.substr(start));
    }
    std::vector<const Counts::value_type*> entries;
    entries.reserve(counts.size());
    for (const auto& entry : counts) entries.push_back(&entry);
    std::sort(entries.begin(), entries.end(), [](const auto* left, const auto* right) {
        return left->first < right->first;
    });
    for (const auto* entry : entries) std::cout << entry->first << ' ' << entry->second << '\n';
    std::cout.flush();
    return static_cast<bool>(std::cout);
}

struct Payload {
    std::uint64_t id;
    std::array<std::uint8_t, 56> bytes;
};

static_assert(sizeof(Payload) == 64);

void lifecycle() {
    std::array<std::unique_ptr<Payload>, batch_size> pointers;
    std::uint64_t sum = 0;
    for (std::size_t cycle = 0; cycle < cycles; ++cycle) {
        for (std::size_t index = 0; index < pointers.size(); ++index) {
            const auto id = static_cast<std::uint64_t>(cycle * batch_size + index);
            auto payload = std::make_unique_for_overwrite<Payload>();
            payload->id = id;
            payload->bytes.fill(static_cast<std::uint8_t>(id));
            pointers[index] = std::move(payload);
        }
        for (auto& pointer : pointers) {
            const Payload* payload = pointer.get();
            asm volatile("" : : "r"(payload) : "memory");
            sum += payload->id + payload->bytes[0];
            pointer.reset();
        }
    }
    std::cout << sum << '\n';
}

int main(int argc, char** argv) {
    std::ios::sync_with_stdio(false);
    if (argc == 2 && std::string_view(argv[1]) == "lifecycle") {
        lifecycle();
        return 0;
    }
    if (argc == 3 && std::string_view(argv[1]) == "words" && words(argv[2])) return 0;
    std::cerr << "could not run benchmark\n";
    return 1;
}

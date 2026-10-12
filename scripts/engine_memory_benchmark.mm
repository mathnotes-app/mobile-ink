#include "SkiaDrawingEngine.h"
#include <mach/mach.h>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>

uint64_t footprint() {
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
    throw std::runtime_error("Could not read process physical footprint");
  }
  return info.phys_footprint;
}
int main() {
  try {
    auto before = footprint();
    std::vector<std::unique_ptr<nativedrawing::SkiaDrawingEngine>> engines;
    for (int i = 0; i < 3; i++) {
      engines.push_back(std::make_unique<nativedrawing::SkiaDrawingEngine>(2064, 2670));
    }
    auto after = footprint();
    std::cout << "{\"before\":" << before << ",\"after\":" << after
              << ",\"delta\":" << (static_cast<int64_t>(after) - static_cast<int64_t>(before)) << "}\n";
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}

# windows_receiver/CMakeLists.txt
cmake_minimum_required(VERSION 3.14)
project(ZapShareAudioReceiver)

set(CMAKE_CXX_STANDARD 17)

include(FetchContent)

# Fetch Opus
FetchContent_Declare(
  opus
  GIT_REPOSITORY https://github.com/xiph/opus.git
  GIT_TAG        v1.4
)

# Disable Opus docs and tests
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)

if(POLICY CMP0169)
  cmake_policy(SET CMP0169 OLD)
endif()

set(SAVED_CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")
set(CMAKE_INSTALL_PREFIX "${CMAKE_CURRENT_BINARY_DIR}/opus-install")
FetchContent_GetProperties(opus)
if(NOT opus_POPULATED)
  FetchContent_Populate(opus)
  add_subdirectory("${opus_SOURCE_DIR}" "${opus_BINARY_DIR}" EXCLUDE_FROM_ALL)
endif()
set(CMAKE_INSTALL_PREFIX "${SAVED_CMAKE_INSTALL_PREFIX}")

add_executable(ZapShareAudioReceiver main.cpp)

# Link Opus and Windows libraries
target_link_libraries(ZapShareAudioReceiver PRIVATE opus ws2_32 ole32)

install(TARGETS ZapShareAudioReceiver RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

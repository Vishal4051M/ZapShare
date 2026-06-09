cmake_minimum_required(VERSION 3.14)
project(ZapShareAudioSender LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)

add_executable(ZapShareAudioSender main.cpp)
target_compile_definitions(ZapShareAudioSender PRIVATE NOMINMAX)
target_link_libraries(ZapShareAudioSender PRIVATE ws2_32 ole32 avrt)

install(TARGETS ZapShareAudioSender RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

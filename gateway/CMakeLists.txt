cmake_minimum_required(VERSION 3.16)
project(zed_web_gateway)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(sensor_msgs REQUIRED)
find_package(point_cloud_interfaces REQUIRED)
find_package(Boost 1.74 REQUIRED)
find_package(Threads REQUIRED)

add_executable(zed_web_gateway src/main.cpp)
ament_target_dependencies(
  zed_web_gateway
  rclcpp
  sensor_msgs
  point_cloud_interfaces
)
target_link_libraries(
  zed_web_gateway
  Threads::Threads
)
target_compile_definitions(zed_web_gateway PRIVATE BOOST_ERROR_CODE_HEADER_ONLY)
target_compile_options(
  zed_web_gateway
  PRIVATE
  -Wall
  -Wextra
  -Wpedantic
)

install(TARGETS zed_web_gateway DESTINATION lib/${PROJECT_NAME})
ament_package()

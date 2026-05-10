cmake_minimum_required(VERSION 3.20)

project(
  MetalGraph
  VERSION 0.1.0
  DESCRIPTION "Reusable explicit graph execution API over Apple Metal"
  LANGUAGES C
)

include(CTest)

add_library(metal_graph STATIC
  src/metal_graph.c
)

add_library(MetalGraph::metal_graph ALIAS metal_graph)

target_compile_features(metal_graph PUBLIC c_std_11)
target_include_directories(metal_graph
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
)

set_target_properties(metal_graph PROPERTIES
  OUTPUT_NAME metal_graph
  PUBLIC_HEADER include/metal_graph/metal_graph.h
)

if(BUILD_TESTING)
  add_executable(metal_graph_smoke_test
    tests/smoke_test.c
  )
  target_link_libraries(metal_graph_smoke_test PRIVATE MetalGraph::metal_graph)
  add_test(NAME metal_graph_smoke_test COMMAND metal_graph_smoke_test)
endif()

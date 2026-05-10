cmake_minimum_required(VERSION 3.20)

project(
  MetalGraph
  VERSION 0.1.0
  DESCRIPTION "Reusable explicit graph execution API over Apple Metal"
  LANGUAGES C CXX
)

include(CTest)

option(MG_ENABLE_MPSGRAPH "Enable optional MPSGraph node backend on Apple platforms" ON)
option(MG_ENABLE_MLX_ADAPTER "Build the optional shared library used by the Python/MLX adapter" ON)

set(MG_BACKEND_SOURCE src/metal/unsupported_backend.c)
if(APPLE)
  enable_language(OBJCXX)
  set(MG_BACKEND_SOURCE src/metal/metal_backend.mm)
endif()

set(MG_LIBRARY_SOURCES
  src/core/arena.c
  src/core/buffer.c
  src/core/error.c
  src/core/graph.c
  src/core/patch.c
  src/core/version.c
  ${MG_BACKEND_SOURCE}
)

add_library(metal_graph STATIC
  ${MG_LIBRARY_SOURCES}
)

add_library(MetalGraph::metal_graph ALIAS metal_graph)

target_compile_features(metal_graph PUBLIC c_std_11)
target_compile_options(metal_graph PRIVATE
  $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
)
target_include_directories(metal_graph
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
)

if(APPLE)
  find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
  find_library(METAL_FRAMEWORK Metal REQUIRED)
  find_library(METAL_PERFORMANCE_SHADERS_FRAMEWORK MetalPerformanceShaders)
  find_library(METAL_PERFORMANCE_SHADERS_GRAPH_FRAMEWORK MetalPerformanceShadersGraph)
  target_link_libraries(metal_graph
    PUBLIC
      ${FOUNDATION_FRAMEWORK}
      ${METAL_FRAMEWORK}
  )
  if(MG_ENABLE_MPSGRAPH AND METAL_PERFORMANCE_SHADERS_FRAMEWORK AND METAL_PERFORMANCE_SHADERS_GRAPH_FRAMEWORK)
    target_compile_definitions(metal_graph PRIVATE MG_ENABLE_MPSGRAPH=1)
    target_link_libraries(metal_graph
      PUBLIC
        ${METAL_PERFORMANCE_SHADERS_FRAMEWORK}
        ${METAL_PERFORMANCE_SHADERS_GRAPH_FRAMEWORK}
    )
    set(MG_HAS_MPSGRAPH TRUE)
  else()
    target_compile_definitions(metal_graph PRIVATE MG_ENABLE_MPSGRAPH=0)
    set(MG_HAS_MPSGRAPH FALSE)
  endif()
else()
  target_compile_definitions(metal_graph PRIVATE MG_ENABLE_MPSGRAPH=0)
  set(MG_HAS_MPSGRAPH FALSE)
endif()

set_target_properties(metal_graph PROPERTIES
  OUTPUT_NAME metal_graph
  PUBLIC_HEADER include/metal_graph/metal_graph.h
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  OBJCXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN YES
)

if(MG_ENABLE_MLX_ADAPTER)
  add_library(metal_graph_shared SHARED
    ${MG_LIBRARY_SOURCES}
  )
  target_compile_features(metal_graph_shared PUBLIC c_std_11)
  target_compile_options(metal_graph_shared PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
  )
  target_include_directories(metal_graph_shared
    PUBLIC
      $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
      $<INSTALL_INTERFACE:include>
  )
  if(APPLE)
    target_link_libraries(metal_graph_shared
      PUBLIC
        ${FOUNDATION_FRAMEWORK}
        ${METAL_FRAMEWORK}
    )
    if(MG_HAS_MPSGRAPH)
      target_compile_definitions(metal_graph_shared PRIVATE MG_ENABLE_MPSGRAPH=1)
      target_link_libraries(metal_graph_shared
        PUBLIC
          ${METAL_PERFORMANCE_SHADERS_FRAMEWORK}
          ${METAL_PERFORMANCE_SHADERS_GRAPH_FRAMEWORK}
      )
    else()
      target_compile_definitions(metal_graph_shared PRIVATE MG_ENABLE_MPSGRAPH=0)
    endif()
  else()
    target_compile_definitions(metal_graph_shared PRIVATE MG_ENABLE_MPSGRAPH=0)
  endif()
  set_target_properties(metal_graph_shared PROPERTIES
    OUTPUT_NAME metal_graph_shared
    C_VISIBILITY_PRESET hidden
    CXX_VISIBILITY_PRESET hidden
    OBJCXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
  )
endif()

if(BUILD_TESTING)
  add_executable(metal_graph_smoke_test
    tests/smoke_test.c
  )
  target_link_libraries(metal_graph_smoke_test PRIVATE MetalGraph::metal_graph)
  add_test(NAME metal_graph_smoke_test COMMAND metal_graph_smoke_test)

  add_executable(metal_graph_unit_test
    tests/unit/graph_unit_test.c
  )
  target_link_libraries(metal_graph_unit_test PRIVATE MetalGraph::metal_graph)
  add_test(NAME metal_graph_unit_test COMMAND metal_graph_unit_test)

  add_executable(metal_graph_public_header_cpp_test
    tests/unit/public_header_cpp_test.cpp
  )
  target_link_libraries(metal_graph_public_header_cpp_test PRIVATE MetalGraph::metal_graph)
  add_test(NAME metal_graph_public_header_cpp_test COMMAND metal_graph_public_header_cpp_test)

  if(APPLE)
    find_program(XCRUN_EXECUTABLE xcrun)
    set(MG_HAS_METAL_TOOLCHAIN FALSE)
    if(XCRUN_EXECUTABLE)
      execute_process(
        COMMAND ${XCRUN_EXECUTABLE} -sdk macosx metal -v
        RESULT_VARIABLE MG_METAL_TOOLCHAIN_RESULT
        OUTPUT_QUIET
        ERROR_QUIET
      )
      if(MG_METAL_TOOLCHAIN_RESULT EQUAL 0)
        set(MG_HAS_METAL_TOOLCHAIN TRUE)
      endif()
    endif()

    if(MG_HAS_METAL_TOOLCHAIN)
      set(MG_TEST_METALLIB ${CMAKE_CURRENT_BINARY_DIR}/phase0_test_kernels.metallib)
      set(MG_TEST_AIR ${CMAKE_CURRENT_BINARY_DIR}/phase0_test_kernels.air)
      add_custom_command(
        OUTPUT ${MG_TEST_METALLIB}
        COMMAND ${XCRUN_EXECUTABLE} -sdk macosx metal
                -c ${CMAKE_CURRENT_SOURCE_DIR}/src/shaders/phase0_test_kernels.metal
                -o ${MG_TEST_AIR}
        COMMAND ${XCRUN_EXECUTABLE} -sdk macosx metallib
                ${MG_TEST_AIR}
                -o ${MG_TEST_METALLIB}
        DEPENDS src/shaders/phase0_test_kernels.metal
        VERBATIM
      )
      add_custom_target(metal_graph_test_metallib DEPENDS ${MG_TEST_METALLIB})

      add_executable(metal_graph_metal_dispatch_test
        tests/gpu/metal_dispatch_test.c
      )
      add_dependencies(metal_graph_metal_dispatch_test metal_graph_test_metallib)
      target_compile_definitions(metal_graph_metal_dispatch_test PRIVATE
        TEST_METALLIB_PATH="${MG_TEST_METALLIB}"
      )
      target_link_libraries(metal_graph_metal_dispatch_test PRIVATE MetalGraph::metal_graph)
      add_test(NAME metal_graph_metal_dispatch_test COMMAND metal_graph_metal_dispatch_test)

      if(MG_HAS_MPSGRAPH)
        add_executable(metal_graph_mpsgraph_node_test
          tests/gpu/mpsgraph_node_test.mm
        )
        add_dependencies(metal_graph_mpsgraph_node_test metal_graph_test_metallib)
        target_compile_options(metal_graph_mpsgraph_node_test PRIVATE -fobjc-arc)
        target_compile_definitions(metal_graph_mpsgraph_node_test PRIVATE
          TEST_METALLIB_PATH="${MG_TEST_METALLIB}"
        )
        target_link_libraries(metal_graph_mpsgraph_node_test PRIVATE MetalGraph::metal_graph)
        add_test(NAME metal_graph_mpsgraph_node_test COMMAND metal_graph_mpsgraph_node_test)
      endif()
    else()
      message(WARNING "Metal Toolchain is unavailable; skipping Metal GPU integration test target")
    endif()

    if(NOT MG_HAS_MPSGRAPH)
      add_executable(metal_graph_mpsgraph_disabled_test
        tests/gpu/mpsgraph_disabled_test.c
      )
      target_link_libraries(metal_graph_mpsgraph_disabled_test PRIVATE MetalGraph::metal_graph)
      add_test(NAME metal_graph_mpsgraph_disabled_test COMMAND metal_graph_mpsgraph_disabled_test)
    endif()
  endif()
endif()

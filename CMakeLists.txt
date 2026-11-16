cmake_minimum_required(VERSION 3.20)

project(
  MetalGraph
  VERSION 0.2.0
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
  src/core/launch.c
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
  PUBLIC_HEADER "include/metal_graph/metal_graph.h;include/metal_graph/metal_graph_metal.h"
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

  if(NOT APPLE)
    add_executable(metal_graph_metal_event_unsupported_test tests/unit/metal_event_unsupported_test.c)
    target_link_libraries(metal_graph_metal_event_unsupported_test PRIVATE MetalGraph::metal_graph)
    add_test(NAME metal_graph_metal_event_unsupported_test COMMAND metal_graph_metal_event_unsupported_test)
  endif()

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

      add_executable(metal_graph_external_buffer_test
        tests/gpu/metal_external_buffer_test.mm
      )
      add_dependencies(metal_graph_external_buffer_test metal_graph_test_metallib)
      target_compile_options(metal_graph_external_buffer_test PRIVATE -fobjc-arc)
      target_compile_definitions(metal_graph_external_buffer_test PRIVATE
        TEST_METALLIB_PATH="${MG_TEST_METALLIB}"
      )
      target_link_libraries(metal_graph_external_buffer_test PRIVATE MetalGraph::metal_graph)
      add_test(NAME metal_graph_external_buffer_test COMMAND metal_graph_external_buffer_test)

      add_executable(hazard_fence_test tests/gpu/hazard_fence_test.mm)
      target_compile_options(hazard_fence_test PRIVATE -fobjc-arc)
      target_link_libraries(hazard_fence_test PRIVATE MetalGraph::metal_graph)
      add_dependencies(hazard_fence_test metal_graph_test_metallib)
      target_compile_definitions(hazard_fence_test PRIVATE TEST_METALLIB_PATH="${MG_TEST_METALLIB}")
      add_test(NAME hazard_fence_test COMMAND hazard_fence_test)
      set_tests_properties(hazard_fence_test PROPERTIES TIMEOUT 20 SKIP_RETURN_CODE 77)

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

    # Blit, event and lifetime checks do not need the offline shader compiler.
    add_executable(metal_graph_public_write_hazards_test tests/gpu/public_write_hazards_test.c)
    target_link_libraries(metal_graph_public_write_hazards_test PRIVATE MetalGraph::metal_graph)
    add_test(NAME metal_graph_public_write_hazards_test COMMAND metal_graph_public_write_hazards_test)
    set_tests_properties(metal_graph_public_write_hazards_test PROPERTIES TIMEOUT 20 SKIP_RETURN_CODE 77)

    add_executable(metal_graph_sync_conformance_test
      tests/gpu/metal_sync_conformance_test.mm
    )
    target_compile_options(metal_graph_sync_conformance_test PRIVATE -fobjc-arc)
    target_link_libraries(metal_graph_sync_conformance_test PRIVATE MetalGraph::metal_graph)
    add_test(NAME metal_graph_sync_conformance_test COMMAND metal_graph_sync_conformance_test)
    set_tests_properties(metal_graph_sync_conformance_test PROPERTIES TIMEOUT 30 SKIP_RETURN_CODE 77)

    foreach(case_name hazard_lock hazard_event hazard_reservation hazard_rejected_owner hazard_topology)
      add_executable(${case_name}_test tests/gpu/${case_name}_test.mm)
      target_compile_options(${case_name}_test PRIVATE -fobjc-arc)
      target_link_libraries(${case_name}_test PRIVATE MetalGraph::metal_graph)
    endforeach()
    add_test(NAME hazard_rejected_owner_test COMMAND hazard_rejected_owner_test)
    add_test(NAME hazard_topology_test COMMAND hazard_topology_test)
    add_test(NAME hazard_same_stream_test COMMAND hazard_reservation_test same-stream)
    set_tests_properties(hazard_same_stream_test hazard_topology_test PROPERTIES TIMEOUT 20 SKIP_RETURN_CODE 77)
    foreach(mode producer-first waiter-first same-queue retired-spoiler early-signal late-wait wrong-target blocked-producer self-cycle producer-precommit-failure advancing-lower-signal)
      add_test(NAME hazard_event_${mode} COMMAND hazard_event_test ${mode})
      set_tests_properties(hazard_event_${mode} PROPERTIES TIMEOUT 20 SKIP_RETURN_CODE 77)
    endforeach()
    foreach(mode normal postcommit)
      add_test(NAME hazard_reservation_${mode} COMMAND hazard_reservation_test ${mode})
      set_tests_properties(hazard_reservation_${mode} PROPERTIES TIMEOUT 20 SKIP_RETURN_CODE 77)
    endforeach()
    add_test(NAME hazard_lock_test COMMAND hazard_lock_test)
    set_tests_properties(hazard_lock_test PROPERTIES TIMEOUT 20 SKIP_RETURN_CODE 77)
    set_tests_properties(hazard_rejected_owner_test PROPERTIES TIMEOUT 20 SKIP_RETURN_CODE 77)

    # Shared-event blit tests do not require the optional offline shader compiler.
    add_executable(metal_graph_metal_event_bridge_test tests/gpu/metal_event_bridge_test.mm)
    target_compile_options(metal_graph_metal_event_bridge_test PRIVATE -fobjc-arc)
    target_link_libraries(metal_graph_metal_event_bridge_test PRIVATE MetalGraph::metal_graph)
    add_test(NAME metal_graph_metal_event_bridge_test COMMAND metal_graph_metal_event_bridge_test)
    set_tests_properties(metal_graph_metal_event_bridge_test PROPERTIES TIMEOUT 30 SKIP_RETURN_CODE 77)

    add_executable(metal_graph_metal_event_early_destroy_test tests/gpu/metal_event_early_destroy_test.mm)
    target_compile_options(metal_graph_metal_event_early_destroy_test PRIVATE -fobjc-arc)
    target_link_libraries(metal_graph_metal_event_early_destroy_test PRIVATE MetalGraph::metal_graph)
    add_test(NAME metal_graph_metal_event_early_destroy_test COMMAND metal_graph_metal_event_early_destroy_test)
    set_tests_properties(metal_graph_metal_event_early_destroy_test PROPERTIES TIMEOUT 30 SKIP_RETURN_CODE 77)

    if(NOT MG_HAS_MPSGRAPH)
      add_executable(metal_graph_mpsgraph_disabled_test
        tests/gpu/mpsgraph_disabled_test.c
      )
      target_link_libraries(metal_graph_mpsgraph_disabled_test PRIVATE MetalGraph::metal_graph)
      add_test(NAME metal_graph_mpsgraph_disabled_test COMMAND metal_graph_mpsgraph_disabled_test)
    endif()
  endif()
endif()

if(APPLE)
  add_executable(metal_graph_shared_event_example examples/metal/shared_event_bridge.mm)
  target_compile_options(metal_graph_shared_event_example PRIVATE -fobjc-arc)
  target_link_libraries(metal_graph_shared_event_example PRIVATE MetalGraph::metal_graph)
  if(BUILD_TESTING)
    add_test(NAME metal_graph_shared_event_example COMMAND metal_graph_shared_event_example)
    set_tests_properties(metal_graph_shared_event_example PROPERTIES TIMEOUT 20 SKIP_RETURN_CODE 77)
  endif()
endif()

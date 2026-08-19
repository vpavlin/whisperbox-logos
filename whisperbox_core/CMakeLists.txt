cmake_minimum_required(VERSION 3.14)
project(WhisperboxCorePlugin LANGUAGES CXX)
if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/cmake/LogosModule.cmake")
    include(cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found")
endif()
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/metadata.json" METADATA_JSON)
string(JSON MODULE_NAME GET ${METADATA_JSON} name)
find_package(OpenSSL REQUIRED)
logos_module(
    NAME ${MODULE_NAME}
    SOURCES
        src/whisperbox_core_impl.h
        src/whisperbox_core_impl.cpp
        src/whisperbox_types.hpp
        src/whisperbox_crypto.hpp
        src/whisperbox_identity.hpp
        src/whisperbox_engine.hpp
        src/whisperbox_wire.hpp
        src/qrcodegen.hpp
        src/qrcodegen.cpp
    INCLUDE_DIRS src
    FIND_PACKAGES OpenSSL
    LINK_LIBRARIES OpenSSL::Crypto
)

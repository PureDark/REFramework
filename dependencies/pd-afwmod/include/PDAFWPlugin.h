#pragma once
#include <cmath>
#include <d3d11_4.h>
#include <d3d12.h>
#include <dxgi1_2.h>
#include <../../../dependencies/glm/glm/glm.hpp>
#include "../../../build64_all/_deps/directxtk12-src/Src/d3dx12.h"

namespace pd {
	struct DeviceParams
	{
		ID3D11Device*        d3d11Device = NULL;
		ID3D11DeviceContext* d3d11Context = NULL;
		ID3D12Device*        d3d12Device = NULL;
		ID3D12CommandQueue*  d3d12Queue = NULL;
		IDXGIAdapter*        dxgiAdapter = NULL;
	};

	struct FrameWarpInitParams
	{
		int hmdWidth;
		int hmdHeight;
		DXGI_FORMAT eyeFormat = DXGI_FORMAT_R8G8B8A8_UNORM;
		DXGI_FORMAT backbufferFormat = DXGI_FORMAT_R10G10B10A2_UNORM;
	};

	enum EyeIndex
	{
		EyeLeft = 0,
		EyeRight = 1
	};

	enum FrameWarpMode
	{
		None,
		AlternateEyeWarping,
		PreviousFrameWarping,
		CombinedWarping
	};

	enum ImageType
	{
		Image,
		depth
	};

	struct TextureDesc
	{
		TextureDesc() {};
		ImageType                     type = Image;
		ID3D12Resource*               pTexture = nullptr;
		int                           srvPos = -1;
		int                           uavPos = -1;
		CD3DX12_GPU_DESCRIPTOR_HANDLE shaderResourceViewHandle;
		CD3DX12_GPU_DESCRIPTOR_HANDLE unorderedAccessViewHandle;
		union
		{
			CD3DX12_CPU_DESCRIPTOR_HANDLE renderTargetViewHandle;
			CD3DX12_CPU_DESCRIPTOR_HANDLE depthStencilViewHandle;
		};
		D3D12_RESOURCE_STATES initialState = D3D12_RESOURCE_STATE_COMMON;
	};

	struct FrameBufferDesc
	{
		FrameBufferDesc() {};
		FrameBufferDesc(TextureDesc InColor, TextureDesc InDepth, TextureDesc InMotionVectors)
		{
			color = InColor;
			depth = InDepth;
			motionVectors = InMotionVectors;
		};
		TextureDesc color;
		TextureDesc depth;
		TextureDesc motionVectors;
	};

	struct EyeFrameBuffers
	{
		FrameBufferDesc eyeFrameBuffers[2];
	};

	struct CameraData
	{
		glm::mat4 destWorldToViewMatrix;
		glm::mat4 destViewToWorldMatrix;
		glm::mat4 destViewToClipMatrix;
		glm::mat4 destClipToViewMatrix;
		glm::mat4 srcWorldToViewMatrix;
		glm::mat4 srcViewToWorldMatrix;
		glm::mat4 srcViewToClipMatrix;
		glm::mat4 srcClipToViewMatrix;
		glm::mat4 camWorldToViewMatrix;  // the camera matrices are for rendering UI to the original camera orientation,
		glm::mat4 camViewToWorldMatrix;  // so that the HMD can move around and looking at different angle without moving the UI.
		glm::mat4 camViewToClipMatrix;   // if you handled the UI yourself you can leave the camera matrices empty.
		glm::mat4 camClipToViewMatrix;   // but it's usually harder to render UI to reprojected image yourself.
	};

	struct FrameWarpEvaluateParams
	{
		void*            InCmdList = NULL;            // optional, leave it NULL to use the built-in command list, which will execute immediately so better to submit your own command lists before calling
		FrameBufferDesc* InEyeFrameBuffer = NULL;     // required, needs to be in pixel shader resource state
		FrameBufferDesc* OutEyeFrameBuffer = NULL;    // returns reprojected result, which is one of the framebuffer you got from calling InitFrameWarp
		TextureDesc*     InUIColorAlpha = NULL;       // optional, provide the UI and the plugin will render it according to the camera orientation without the HMD rotaion and position affecting it.
		float            InUIScale[2] = { 1.0f, 1.0f };
		float            InUIPos[3] = { 0.0f, 0.0f, -1.0f };
		float            InMotionScale[2] = { 0.0f, 0.0f };
		FrameWarpMode	 Mode;
		EyeIndex         EyeIndex;
		CameraData*      CameraData;  // required, camera matrices for this frame
		bool             ClearBeforeWarping = false;
		float            IgnoreMotionThreshold{ 2.5f };    // per-object motion vectors, ignore threshold in pixel space
		bool             IsHudlessColor = true;    // specify whether InEyeColor is hudless or contaning UI, if the latter, will use UIColorAndAlpha to avoid reprojecting UI.
		bool             IsMotionVectorsOtherEye = false;  // whether motion vectors include motion from camera jumping between eyes
		bool             Debug = false;
	};

	struct TonemapParams
	{
		float fGamma;
		float fLowerLimit;
		float fUpperLimit;
		float fConvertToLimit;
	};

	struct __declspec(novtable) D3D12RendererAPI
	{
		virtual ID3D12GraphicsCommandList*  BeginCommandList(int index) = 0;
		virtual void                        EndCommandList(int index) = 0;
		virtual void                        WaitIdle(int index) = 0;
		virtual ID3D12Device*               GetDevice() = 0;
		virtual ID3D12CommandQueue*         GetCommandQueue() = 0;
		virtual ID3D12DescriptorHeap*       GetViewHeap() = 0;
		virtual D3D12_CPU_DESCRIPTOR_HANDLE GetRTV(ID3D12Resource* resource) = 0;
		virtual D3D12_CPU_DESCRIPTOR_HANDLE GetDSV(ID3D12Resource* resource) = 0;
		virtual int                         CreateSRV(ID3D12Resource* resource, int pos = -1) = 0;
		virtual int                         CreateUAV(ID3D12Resource* resource, int pos = -1) = 0;
		virtual int                         CreateCBV(ID3D12Resource* resource, int pos = -1) = 0;
		virtual D3D12_CPU_DESCRIPTOR_HANDLE GetCPUDescriptorHandle(int pos) = 0;
		virtual D3D12_GPU_DESCRIPTOR_HANDLE GetGPUDescriptorHandle(int pos) = 0;
		virtual D3D12_GPU_DESCRIPTOR_HANDLE GetSamplerHandle(int pos) = 0;
		virtual bool                        CreateTexture(int nWidth, int nHeight, DXGI_FORMAT format, D3D12_RESOURCE_STATES initialState, TextureDesc& textureDesc, bool createUAV) = 0;
		virtual bool                        CreateFrameBuffer(int nWidth, int nHeight, FrameBufferDesc& framebufferDesc, bool createUAV) = 0;
		virtual void                        Blit(ID3D12GraphicsCommandList* cmdList, TextureDesc& dstDesc, TextureDesc& srcDesc, D3D12_VIEWPORT viewPort, bool enableBlend = false) = 0;
		virtual void                        Copy(ID3D12GraphicsCommandList* cmdList, TextureDesc& dstDesc, TextureDesc& srcDesc) = 0;
		virtual void                        Tonemap(ID3D12GraphicsCommandList* cmdList, TextureDesc& dstDesc, TextureDesc& srcDesc, TonemapParams params) = 0;
		virtual TextureDesc&                ExtractUI(ID3D12GraphicsCommandList* cmdList, TextureDesc& hudlessDesc, TextureDesc& finalColorWithUI) = 0;
	};

	extern "C" __declspec(dllexport) D3D12RendererAPI* __stdcall InitDevice(DeviceParams params);
	extern "C" __declspec(dllexport) EyeFrameBuffers __stdcall InitFrameWarp(FrameWarpInitParams params);
	extern "C" __declspec(dllexport) void __stdcall EvaluateFrameWarp(FrameWarpEvaluateParams& params);
}

using namespace pd;

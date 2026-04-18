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
		Depth
	};

	struct VextexBufferDesc
	{
		ID3D12Resource*          pVextexBuffer = nullptr;
		D3D12_VERTEX_BUFFER_VIEW vertexBufferView;
		D3D12_RESOURCE_STATES    initialState = D3D12_RESOURCE_STATE_COMMON;
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

	// dest -> current eye previous frame
	// src -> current eye current frame (rendered)
	// srcPrev -> other eye previous farme (rendered)
	struct CameraDataMVCorrection
	{
		glm::mat4 destWorldToViewMatrix;
		glm::mat4 destViewToWorldMatrix;
		glm::mat4 destViewToClipMatrix;
		glm::mat4 destClipToViewMatrix;
		glm::mat4 srcWorldToViewMatrix;
		glm::mat4 srcViewToWorldMatrix;
		glm::mat4 srcViewToClipMatrix;
		glm::mat4 srcClipToViewMatrix;
		glm::mat4 srcWorldToViewMatrixPrev;
		glm::mat4 srcViewToWorldMatrixPrev;
		glm::mat4 srcViewToClipMatrixPrev;
		glm::mat4 srcClipToViewMatrixPrev;
	};

	enum MVType
	{
		Normal,        // curr eye curr frame -> curr eye last frame
		FromOtherEye,  // curr eye curr frame -> other eye last frame
		ObjectOnly     // only object motion, no camera motion
	};

	struct FrameWarpEvaluateParams
	{
		void*            InCmdList = NULL;          // optional, leave it NULL to use the built-in command list, which will execute immediately so better to submit your own command lists before calling
		FrameBufferDesc* InEyeFrameBuffer = NULL;   // required, needs to be in pixel shader resource state
		FrameBufferDesc* OutEyeFrameBuffer = NULL;  // returns reprojected result, which is one of the framebuffer you got from calling InitFrameWarp
		TextureDesc*     InUIColorAlpha = NULL;     // optional, provide the UI and the plugin will render it according to the camera orientation without the HMD rotaion and position affecting it.
		float            InUIScale[2] = { 1.0f, 1.0f };
		float            InUIPos[3] = { 0.0f, 0.0f, -1.0f };
		float            InMotionScale[2] = { 0.0f, 0.0f };
		FrameWarpMode    Mode;
		EyeIndex         EyeIndex;
		CameraData*      CameraData;  // required, camera matrices for this frame
		bool             ClearBeforeWarping = false;
		float            IgnoreMotionThreshold{ 2.5f };  // per-object motion vectors, ignore threshold in pixel space
		bool             IsHudlessColor = true;          // specify whether InEyeColor is hudless or contaning UI, if the latter, will use UIColorAndAlpha to avoid reprojecting UI.
		MVType           MotionVectorsType = Normal;
		bool             Debug = false;
	};

	struct TonemapParams
	{
		float fGamma;
		float fLowerLimit;
		float fUpperLimit;
		float fConvertToLimit;
	};

	struct CorrectMotionVectorsParams
	{
		TextureDesc*            inMotionVectors;
		TextureDesc*            inDepth;
		CameraDataMVCorrection* cameraData;
		float                   InMotionScale[2] = { 0.0f, 0.0f };
		bool                    extractObjectOnlyMotion = false;
	};

#define MAX_SHADING_RATES 9
#define SHADING_RATE_SHIFT 3
	enum class ShadingRate1D : uint32_t
	{
		ShadingRate1D_1X = 1 << 0,  ///< 1x1 shading rate.
		ShadingRate1D_2X = 1 << 1,  ///< 1x2 shading rate.
		ShadingRate1D_4X = 1 << 2   ///< 1x4 shading rate.
	};

	inline ShadingRate1D operator|(ShadingRate1D left, ShadingRate1D right)
	{
		return (ShadingRate1D)(((uint32_t)left) | ((uint32_t)right));
	}
	enum class ShadingRate : uint32_t
	{
		ShadingRate_1X1 = ((uint32_t)ShadingRate1D::ShadingRate1D_1X << SHADING_RATE_SHIFT) | (uint32_t)ShadingRate1D::ShadingRate1D_1X,  ///< 1x1 shading rate.
		ShadingRate_1X2 = ((uint32_t)ShadingRate1D::ShadingRate1D_1X << SHADING_RATE_SHIFT) | (uint32_t)ShadingRate1D::ShadingRate1D_2X,  ///< 1x2 shading rate.
		ShadingRate_1X4 = ((uint32_t)ShadingRate1D::ShadingRate1D_1X << SHADING_RATE_SHIFT) | (uint32_t)ShadingRate1D::ShadingRate1D_4X,  ///< 1x4 shading rate.
		ShadingRate_2X1 = ((uint32_t)ShadingRate1D::ShadingRate1D_2X << SHADING_RATE_SHIFT) | (uint32_t)ShadingRate1D::ShadingRate1D_1X,  ///< 2x1 shading rate.
		ShadingRate_2X2 = ((uint32_t)ShadingRate1D::ShadingRate1D_2X << SHADING_RATE_SHIFT) | (uint32_t)ShadingRate1D::ShadingRate1D_2X,  ///< 2x2 shading rate.
		ShadingRate_2X4 = ((uint32_t)ShadingRate1D::ShadingRate1D_2X << SHADING_RATE_SHIFT) | (uint32_t)ShadingRate1D::ShadingRate1D_4X,  ///< 2x4 shading rate.
		ShadingRate_4X1 = ((uint32_t)ShadingRate1D::ShadingRate1D_4X << SHADING_RATE_SHIFT) | (uint32_t)ShadingRate1D::ShadingRate1D_1X,  ///< 4x1 shading rate.
		ShadingRate_4X2 = ((uint32_t)ShadingRate1D::ShadingRate1D_4X << SHADING_RATE_SHIFT) | (uint32_t)ShadingRate1D::ShadingRate1D_2X,  ///< 4x2 shading rate.
		ShadingRate_4X4 = ((uint32_t)ShadingRate1D::ShadingRate1D_4X << SHADING_RATE_SHIFT) | (uint32_t)ShadingRate1D::ShadingRate1D_4X   ///< 4x4 shading rate.
	};
	enum class ShadingRateCombiner : uint32_t
	{
		ShadingRateCombiner_Passthrough = 1 << 0,  ///< Pass through.
		ShadingRateCombiner_Override = 1 << 1,     ///< Override.
		ShadingRateCombiner_Min = 1 << 2,          ///< Minimum.
		ShadingRateCombiner_Max = 1 << 3,          ///< Maximum.
		ShadingRateCombiner_Sum = 1 << 4,          ///< Sum.
		ShadingRateCombiner_Mul = 1 << 5           ///< Multiply.
	};
	inline ShadingRateCombiner operator|(ShadingRateCombiner a, ShadingRateCombiner b) { return ShadingRateCombiner(((int)a) | ((int)b)); }
	inline ShadingRateCombiner operator|=(ShadingRateCombiner& a, ShadingRateCombiner b) { return (ShadingRateCombiner&)(((int&)a) |= ((int)b)); }
	inline ShadingRateCombiner operator&(ShadingRateCombiner a, ShadingRateCombiner b) { return ShadingRateCombiner(((int)a) & ((int)b)); }
	inline ShadingRateCombiner operator&=(ShadingRateCombiner& a, ShadingRateCombiner b) { return (ShadingRateCombiner&)(((int&)a) &= ((int)b)); }
	inline ShadingRateCombiner operator~(ShadingRateCombiner a) { return (ShadingRateCombiner)(~((int)a)); }
	inline ShadingRateCombiner operator^(ShadingRateCombiner a, ShadingRateCombiner b) { return ShadingRateCombiner(((int)a) ^ ((int)b)); }
	inline ShadingRateCombiner operator^=(ShadingRateCombiner& a, ShadingRateCombiner b) { return (ShadingRateCombiner&)(((int&)a) ^= ((int)b)); }

	struct VRSInfo
	{
		bool                AdditionalShadingRatesSupported = false;  ///< True if shading rates over 2xX are supported.
		ShadingRate         ShadingRates[MAX_SHADING_RATES];          ///< Array of shading rates to use.
		uint32_t            NumShadingRates = 0;                      ///< Number of shading rates in shading rates array.
		ShadingRateCombiner Combiners;                                ///< Number of combiners.
		uint32_t            MinTileSize[2];                           ///< Minimum tile size (x, y).
		uint32_t            MaxTileSize[2];                           ///< Maximum tile size (x, y).
	};

	typedef struct VRSFovRadius
	{
		float radius1x1;  ///< The radius of the 1x1 foveated shading rate outer boundary.
		float radius1x2;  ///< The radius of the 1x2 foveated shading rate outer boundary.
		float radius2x2;  ///< The radius of the 2x2 foveated shading rate outer boundary.
		float radius2x4;  ///< The radius of the 2x4 foveated shading rate outer boundary.
	} VRSFovRadius;

	enum VRSAlgorithm
	{
		LuminanceAndMotionVectors = 0x1,
		Foveated = 0x2,
		Combined = LuminanceAndMotionVectors | Foveated
	};

	typedef struct VRSParams
	{
		VRSAlgorithm    vrsAlgorithm = Foveated;          ///< The algorithm to use for the VRS.
		ID3D12Resource* historyColor = NULL;              ///< The color buffer for the previous frame (at presentation resolution).
		ID3D12Resource* motionVectors = NULL;             ///< The velocity buffer for the current frame (at presentation resolution).
		float           renderSize[2] = { 0, 0 };         ///< The resolution that was used for rendering the input resource.
		float           varianceCutoff = 0;               ///< This value specifies how much variance in luminance is acceptable to reduce shading rate.
		float           motionFactor = 0;                 ///< The lower this value, the faster a pixel has to move to get the shading rate reduced.
		uint32_t        tileSize = 0;                     ///< ShadingRateImage tile size.
		float           motionVectorScale[2] = { 0, 0 };  ///< Scale motion vectors to different format
		float           foveationCenter[2] = { 0, 0 };    ///< The center of the foveated region.
		VRSFovRadius    foveationRadius;                  ///< The radius of the foveated regions, expected squared by the shader.
	} VRSParams;

	struct FoveatedCompositeParams
	{
		float fFadeLeft = 0.05f;
		float fFadeRight = 0.05f;
		float fFadeTop = 0.05f;
		float fFadeBottom = 0.05f;
		int   bRoundedCorner = 1;
		float fRoundedRadius = 0.1f;
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
		virtual void                        SetupTextureDesc(TextureDesc& srcDesc) = 0;
		virtual bool                        CreateVertexBuffer(ID3D12GraphicsCommandList* cmdList, VextexBufferDesc& vextexDesc, uint32_t vertexCount, uint32_t vertexSize, float* pVertexData);
		virtual bool                        CreateTexture(int nWidth, int nHeight, DXGI_FORMAT format, D3D12_RESOURCE_STATES initialState, TextureDesc& textureDesc, bool createUAV) = 0;
		virtual bool                        CreateFrameBuffer(int nWidth, int nHeight, FrameBufferDesc& framebufferDesc, D3D12_RESOURCE_STATES initialState, bool createUAV) = 0;
		virtual void                        Clear(ID3D12GraphicsCommandList* cmdList, TextureDesc& texDesc, const FLOAT ColorRGBA[4]) = 0;
		virtual void                        Blit(ID3D12GraphicsCommandList* cmdList, TextureDesc& dstDesc, TextureDesc& srcDesc, D3D12_VIEWPORT viewPort = {}, bool enableBlend = false) = 0;
		virtual void                        Copy(ID3D12GraphicsCommandList* cmdList, TextureDesc& dstDesc, TextureDesc& srcDesc) = 0;
		virtual void                        Sharpen(ID3D12GraphicsCommandList* cmdList, TextureDesc& dstDesc, TextureDesc& srcDesc, float sharpness) = 0;
		virtual void                        Tonemap(ID3D12GraphicsCommandList* cmdList, TextureDesc& dstDesc, TextureDesc& srcDesc, TonemapParams params) = 0;
		virtual void                        ExtractUI(ID3D12GraphicsCommandList* cmdList, TextureDesc& extactedUIDesc, TextureDesc& hudlessDesc, TextureDesc& finalColorWithUI) = 0;
		virtual void                        CorrectMotionVectors(ID3D12GraphicsCommandList* cmdList, TextureDesc& correctedMVDesc, CorrectMotionVectorsParams& params) = 0;
		virtual void                        FoveatedComposite(ID3D12GraphicsCommandList* cmdList, TextureDesc& dstDesc, TextureDesc& srcDesc, D3D12_VIEWPORT viewPort = {}, FoveatedCompositeParams params = {}) = 0;
		virtual void                        ApplyHiddenAreaMesh(ID3D12GraphicsCommandList* cmdList, TextureDesc& depthDesc, D3D12_VIEWPORT viewPort, VextexBufferDesc& vextexDesc) = 0;
		virtual void                        GenerateVRSImage(ID3D12GraphicsCommandList* cmdList, TextureDesc& vrsImageDesc, VRSParams params) = 0;
		virtual VRSInfo                     GetVRSInfo() = 0;
		virtual void                        ShowVRSOverlay(ID3D12GraphicsCommandList* cmdList, TextureDesc& dstDesc, TextureDesc& srcDesc) = 0;
	};

	extern "C" __declspec(dllexport) D3D12RendererAPI* __stdcall InitDevice(DeviceParams params);
	extern "C" __declspec(dllexport) EyeFrameBuffers __stdcall InitFrameWarp(FrameWarpInitParams params);
	extern "C" __declspec(dllexport) void __stdcall EvaluateFrameWarp(FrameWarpEvaluateParams& params);
}

using namespace pd;

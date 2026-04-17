#pragma once

#define NVSDK_NGX_Result_Success 0x1
typedef int NVSDK_NGX_Result;
typedef enum NVSDK_NGX_Feature {
    NVSDK_NGX_Feature_SuperSampling = 1,
    NVSDK_NGX_Feature_RayReconstruction = 13,
} NVSDK_NGX_Feature;
typedef struct NVSDK_NGX_Handle {
    unsigned int Id;
} NVSDK_NGX_Handle;
typedef struct NVSDK_NGX_Parameter {
    virtual void Set(const char* InName, unsigned long long InValue) = 0;
    virtual void Set(const char* InName, float InValue) = 0;
    virtual void Set(const char* InName, double InValue) = 0;
    virtual void Set(const char* InName, unsigned int InValue) = 0;
    virtual void Set(const char* InName, int InValue) = 0;
    virtual void Set(const char* InName, ID3D11Resource* InValue) = 0;
    virtual void Set(const char* InName, ID3D12Resource* InValue) = 0;
    virtual void Set(const char* InName, void* InValue) = 0;

    virtual NVSDK_NGX_Result Get(const char* InName, unsigned long long* OutValue) const = 0;
    virtual NVSDK_NGX_Result Get(const char* InName, float* OutValue) const = 0;
    virtual NVSDK_NGX_Result Get(const char* InName, double* OutValue) const = 0;
    virtual NVSDK_NGX_Result Get(const char* InName, unsigned int* OutValue) const = 0;
    virtual NVSDK_NGX_Result Get(const char* InName, int* OutValue) const = 0;
    virtual NVSDK_NGX_Result Get(const char* InName, ID3D11Resource** OutValue) const = 0;
    virtual NVSDK_NGX_Result Get(const char* InName, ID3D12Resource** OutValue) const = 0;
    virtual NVSDK_NGX_Result Get(const char* InName, void** OutValue) const = 0;

    virtual void Reset() = 0;
} NVSDK_NGX_Parameter;

#define NVSDK_NGX_Parameter_DLSS_Feature_Create_Flags "DLSS.Feature.Create.Flags"
#define NVSDK_NGX_Parameter_OutWidth "OutWidth"
#define NVSDK_NGX_Parameter_OutHeight "OutHeight"
using NVSDK_NGX_D3D12_CreateFeature_t = NVSDK_NGX_Result (*)(ID3D12GraphicsCommandList* InCmdList, NVSDK_NGX_Feature InFeatureID,
    const NVSDK_NGX_Parameter* InParameters, NVSDK_NGX_Handle** OutHandle);
static NVSDK_NGX_D3D12_CreateFeature_t o_NVSDK_NGX_D3D12_CreateFeature = nullptr;
NVSDK_NGX_Result hk_NVSDK_NGX_D3D12_CreateFeature(
    ID3D12GraphicsCommandList* InCmdList, NVSDK_NGX_Feature InFeatureID, NVSDK_NGX_Parameter* InParameters, NVSDK_NGX_Handle** OutHandle);

using NVSDK_NGX_D3D12_ReleaseFeature_t = NVSDK_NGX_Result (*)(NVSDK_NGX_Handle* InHandle);
static NVSDK_NGX_D3D12_ReleaseFeature_t o_NVSDK_NGX_D3D12_ReleaseFeature = nullptr;
NVSDK_NGX_Result hk_NVSDK_NGX_D3D12_ReleaseFeature(NVSDK_NGX_Handle* InHandle);

using NVSDK_NGX_D3D12_EvaluateFeature_t = NVSDK_NGX_Result (*)(
    ID3D12GraphicsCommandList* InCmdList, const NVSDK_NGX_Handle* InFeatureHandle, NVSDK_NGX_Parameter* InParameters, void* InCallback);
static NVSDK_NGX_D3D12_EvaluateFeature_t o_NVSDK_NGX_D3D12_EvaluateFeature = nullptr;
NVSDK_NGX_Result hk_NVSDK_NGX_D3D12_EvaluateFeature(
    ID3D12GraphicsCommandList* InCmdList, const NVSDK_NGX_Handle* InFeatureHandle, NVSDK_NGX_Parameter* InParameters, void* InCallback);


#define NVSDK_NGX_SUCCEED(value) (((value) & 0xFFF00000) != 0xBAD00000)
#define NVSDK_NGX_FAILED(value) (((value) & 0xFFF00000) == 0xBAD00000)
#define NVSDK_NGX_Parameter_Color "Color"
#define NVSDK_NGX_Parameter_Depth "Depth"
#define NVSDK_NGX_Parameter_MotionVectors "MotionVectors"
#define NVSDK_NGX_Parameter_Output "Output"
#define NVSDK_NGX_Parameter_MV_Scale_X "MV.Scale.X"
#define NVSDK_NGX_Parameter_MV_Scale_Y "MV.Scale.Y"



typedef void* ffxContext;
typedef uint32_t ffxReturnCode_t;
typedef uint64_t ffxStructType_t;
typedef struct ffxApiHeader {
    ffxStructType_t type;
    struct ffxApiHeader* pNext;
} ffxApiHeader;
typedef ffxApiHeader ffxCreateContextDescHeader;
typedef ffxApiHeader ffxDispatchDescHeader;
struct FfxApiResource {
    void* resource;
    uint32_t description[8];
    uint32_t state;
};
struct FfxApiDimensions2D {
    uint32_t width;
    uint32_t height;
};
#define FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE 0x00010000u
struct ffxCreateContextDescUpscale {
    ffxCreateContextDescHeader header;
    uint32_t flags;
    struct FfxApiDimensions2D maxRenderSize;
    struct FfxApiDimensions2D maxUpscaleSize;
};

#define FFX_API_DISPATCH_DESC_TYPE_UPSCALE 0x00010001u
struct ffxDispatchDescUpscale {
    ffxDispatchDescHeader header;
    void* commandList;
    struct FfxApiResource color;
    struct FfxApiResource depth;
    struct FfxApiResource motionVectors;
    struct FfxApiResource exposure;
    struct FfxApiResource reactive;
    struct FfxApiResource transparencyAndComposition;
    struct FfxApiResource output;
    float jitterOffset[2];
    float motionVectorScale[2];
    float renderSize[2];
    float upscaleSize[2];
    bool enableSharpening;
    float sharpness;
    float frameTimeDelta;
    float preExposure;
    bool reset;
    float cameraNear;
    float cameraFar;
    float cameraFovAngleVertical;
    float viewSpaceToMetersFactor;
    uint32_t flags;
};

using ffxCreateContext_t = ffxReturnCode_t (*)(ffxContext* context, ffxCreateContextDescHeader* desc, const void** memCb);
static ffxCreateContext_t o_ffxCreateContext = nullptr;
ffxReturnCode_t hk_ffxCreateContext(ffxContext* context, ffxCreateContextDescHeader* desc, const void** memCb);

using ffxDestroyContext_t = ffxReturnCode_t (*)(ffxContext* context, const void** memCb);
static ffxDestroyContext_t o_ffxDestroyContext = nullptr;
ffxReturnCode_t hk_ffxDestroyContext(ffxContext* context, const void** memCb);

using ffxDispatch_t = ffxReturnCode_t (*)(ffxContext* context, const ffxDispatchDescHeader* desc);
static ffxDispatch_t o_ffxDispatch = nullptr;
ffxReturnCode_t hk_ffxDispatch(ffxContext* context, const ffxDispatchDescHeader* desc);

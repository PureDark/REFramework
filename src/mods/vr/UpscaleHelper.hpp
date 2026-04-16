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
NVSDK_NGX_Result hk_NVSDK_NGX_D3D12_EvaluateFeature(
    ID3D12GraphicsCommandList* InCmdList, const NVSDK_NGX_Handle* InFeatureHandle, NVSDK_NGX_Parameter* InParameters, void* InCallback);


#define NVSDK_NGX_SUCCEED(value) (((value) & 0xFFF00000) != 0xBAD00000)
#define NVSDK_NGX_FAILED(value) (((value) & 0xFFF00000) == 0xBAD00000)
#define NVSDK_NGX_Parameter_Color "Color"
#define NVSDK_NGX_Parameter_Depth "Depth"
#define NVSDK_NGX_Parameter_MotionVectors "MotionVectors"
#define NVSDK_NGX_Parameter_Output "Output"
#define NVSDK_NGX_Parameter_Jitter_Offset_X "Jitter.Offset.X"
#define NVSDK_NGX_Parameter_Jitter_Offset_Y "Jitter.Offset.Y"
#define NVSDK_NGX_Parameter_MV_Scale_X "MV.Scale.X"
#define NVSDK_NGX_Parameter_MV_Scale_Y "MV.Scale.Y"
#define NVSDK_NGX_Parameter_Sharpness "Sharpness"
#define NVSDK_NGX_Parameter_Reset "Reset"
#define NVSDK_NGX_Parameter_DLSS_Input_Color_Subrect_Base_X "DLSS.Input.Color.Subrect.Base.X"
#define NVSDK_NGX_Parameter_DLSS_Input_Color_Subrect_Base_Y "DLSS.Input.Color.Subrect.Base.Y"
#define NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_X "DLSS.Input.Depth.Subrect.Base.X"
#define NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_Y "DLSS.Input.Depth.Subrect.Base.Y"
#define NVSDK_NGX_Parameter_DLSS_Input_MV_SubrectBase_X "DLSS.Input.MV.Subrect.Base.X"
#define NVSDK_NGX_Parameter_DLSS_Input_MV_SubrectBase_Y "DLSS.Input.MV.Subrect.Base.Y"
#define NVSDK_NGX_Parameter_DLSS_Input_Translucency_SubrectBase_X "DLSS.Input.Translucency.Subrect.Base.X"
#define NVSDK_NGX_Parameter_DLSS_Input_Translucency_SubrectBase_Y "DLSS.Input.Translucency.Subrect.Base.Y"
#define NVSDK_NGX_Parameter_DLSS_Output_Subrect_Base_X "DLSS.Output.Subrect.Base.X"
#define NVSDK_NGX_Parameter_DLSS_Output_Subrect_Base_Y "DLSS.Output.Subrect.Base.Y"
#define NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width "DLSS.Render.Subrect.Dimensions.Width"
#define NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Height "DLSS.Render.Subrect.Dimensions.Height"
#define NVSDK_NGX_Parameter_DLSS_Pre_Exposure "DLSS.Pre.Exposure"
#define NVSDK_NGX_Parameter_DLSS_Exposure_Scale "DLSS.Exposure.Scale"
#define NVSDK_NGX_Parameter_DLSS_Input_Bias_Current_Color_Mask "DLSS.Input.Bias.Current.Color.Mask"
#define NVSDK_NGX_Parameter_DLSS_Input_Bias_Current_Color_SubrectBase_X "DLSS.Input.Bias.Current.Color.Subrect.Base.X"
#define NVSDK_NGX_Parameter_DLSS_Input_Bias_Current_Color_SubrectBase_Y "DLSS.Input.Bias.Current.Color.Subrect.Base.Y"
#define NVSDK_NGX_Parameter_DLSS_Indicator_Invert_Y_Axis "DLSS.Indicator.Invert.Y.Axis"
#define NVSDK_NGX_Parameter_DLSS_Indicator_Invert_X_Axis "DLSS.Indicator.Invert.X.Axis"

typedef struct NVSDK_NGX_Coordinates {
    unsigned int X = 0;
    unsigned int Y = 0;
} NVSDK_NGX_Coordinates;

typedef struct NVSDK_NGX_Dimensions {
    unsigned int Width = 0;
    unsigned int Height = 0;
} NVSDK_NGX_Dimensions;

typedef struct NVSDK_NGX_D3D12_Feature_Eval_Params {
    ID3D12Resource* pInColor;
    ID3D12Resource* pInOutput;
} NVSDK_NGX_D3D12_Feature_Eval_Params;

typedef struct NVSDK_NGX_D3D12_DLSS_Eval_Params {
    NVSDK_NGX_D3D12_Feature_Eval_Params Feature;
    ID3D12Resource* pInDepth;
    ID3D12Resource* pInMotionVectors;
    float InJitterOffsetX; /* Jitter offset must be in input/render pixel space */
    float InJitterOffsetY;
    NVSDK_NGX_Dimensions InRenderSubrectDimensions;  /*** OPTIONAL - leave to 0/0.0f if unused ***/
    int InReset;      /* Set to 1 when scene changes completely (new level etc) */
    float InMVScaleX; /* If MVs need custom scaling to convert to pixel space */
    float InMVScaleY;
    ID3D12Resource* pInTransparencyMask = NULL;
    ID3D12Resource* pInExposureTexture = NULL;
    ID3D12Resource* pInBiasCurrentColorMask = NULL;
    NVSDK_NGX_Coordinates InColorSubrectBase = {};
    NVSDK_NGX_Coordinates InDepthSubrectBase = {};
    NVSDK_NGX_Coordinates InMVSubrectBase = {};
    NVSDK_NGX_Coordinates InTranslucencySubrectBase = {};
    NVSDK_NGX_Coordinates InBiasCurrentColorSubrectBase = {};
    NVSDK_NGX_Coordinates InOutputSubrectBase = {};
    float InPreExposure = 0.0f;
    float InExposureScale = 0.0f;
    int InIndicatorInvertXAxis = 0;
    int InIndicatorInvertYAxis = 0;
} NVSDK_NGX_D3D12_DLSS_Eval_Params;

static inline NVSDK_NGX_Result NGX_D3D12_EVALUATE_DLSS_EXT(
    NVSDK_NGX_D3D12_EvaluateFeature_t o_NVSDK_NGX_D3D12_EvaluateFeature,
    ID3D12GraphicsCommandList *pInCmdList,
    NVSDK_NGX_Handle *pInHandle,
    NVSDK_NGX_Parameter *pInParams,
    NVSDK_NGX_D3D12_DLSS_Eval_Params *pInDlssEvalParams)
{
    if (!o_NVSDK_NGX_D3D12_EvaluateFeature)
        return 0;
    pInParams->Set(NVSDK_NGX_Parameter_Color, pInDlssEvalParams->Feature.pInColor);
    pInParams->Set(NVSDK_NGX_Parameter_Output, pInDlssEvalParams->Feature.pInOutput);
    pInParams->Set(NVSDK_NGX_Parameter_Depth, pInDlssEvalParams->pInDepth);
    pInParams->Set(NVSDK_NGX_Parameter_MotionVectors, pInDlssEvalParams->pInMotionVectors);
    pInParams->Set(NVSDK_NGX_Parameter_Jitter_Offset_X, pInDlssEvalParams->InJitterOffsetX);
    pInParams->Set(NVSDK_NGX_Parameter_Jitter_Offset_Y, pInDlssEvalParams->InJitterOffsetY);
    pInParams->Set(NVSDK_NGX_Parameter_Sharpness, 0);
    pInParams->Set(NVSDK_NGX_Parameter_Reset, pInDlssEvalParams->InReset);
    pInParams->Set(NVSDK_NGX_Parameter_MV_Scale_X, pInDlssEvalParams->InMVScaleX == 0.0f ? 1.0f : pInDlssEvalParams->InMVScaleX);
    pInParams->Set(NVSDK_NGX_Parameter_MV_Scale_Y, pInDlssEvalParams->InMVScaleY == 0.0f ? 1.0f : pInDlssEvalParams->InMVScaleY);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Input_Color_Subrect_Base_X, pInDlssEvalParams->InColorSubrectBase.X);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Input_Color_Subrect_Base_Y, pInDlssEvalParams->InColorSubrectBase.Y);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_X, pInDlssEvalParams->InDepthSubrectBase.X);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_Y, pInDlssEvalParams->InDepthSubrectBase.Y);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Input_MV_SubrectBase_X, pInDlssEvalParams->InMVSubrectBase.X);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Input_MV_SubrectBase_Y, pInDlssEvalParams->InMVSubrectBase.Y);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Input_Translucency_SubrectBase_X, pInDlssEvalParams->InTranslucencySubrectBase.X);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Input_Translucency_SubrectBase_Y, pInDlssEvalParams->InTranslucencySubrectBase.Y);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Input_Bias_Current_Color_SubrectBase_X, pInDlssEvalParams->InBiasCurrentColorSubrectBase.X);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Input_Bias_Current_Color_SubrectBase_Y, pInDlssEvalParams->InBiasCurrentColorSubrectBase.Y);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Output_Subrect_Base_X, pInDlssEvalParams->InOutputSubrectBase.X);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Output_Subrect_Base_Y, pInDlssEvalParams->InOutputSubrectBase.Y);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width , pInDlssEvalParams->InRenderSubrectDimensions.Width);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Height, pInDlssEvalParams->InRenderSubrectDimensions.Height);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Pre_Exposure, pInDlssEvalParams->InPreExposure == 0.0f ? 1.0f : pInDlssEvalParams->InPreExposure);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Exposure_Scale, pInDlssEvalParams->InExposureScale == 0.0f ? 1.0f : pInDlssEvalParams->InExposureScale);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Indicator_Invert_X_Axis, pInDlssEvalParams->InIndicatorInvertXAxis);
    pInParams->Set(NVSDK_NGX_Parameter_DLSS_Indicator_Invert_Y_Axis, pInDlssEvalParams->InIndicatorInvertYAxis);

    return o_NVSDK_NGX_D3D12_EvaluateFeature(pInCmdList, pInHandle, pInParams, NULL);
}









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
ffxReturnCode_t hk_ffxDispatch(ffxContext* context, const ffxDispatchDescHeader* desc);

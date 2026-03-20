// dummy implementation of the DLL so I don't need to commit the DLL to the repo
#include "../include/PDAFWPlugin.h"

namespace pd {
	D3D12RendererAPI* __stdcall InitDevice(DeviceParams params){ return nullptr; };
	EyeFrameBuffers __stdcall InitFrameWarp(FrameWarpInitParams params){ return EyeFrameBuffers(); };
	void __stdcall EvaluateFrameWarp(FrameWarpEvaluateParams& params){};
}
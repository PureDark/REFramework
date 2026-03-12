// dummy implementation of the DLL so I don't need to commit the DLL to the repo
#include "../include/PDReprojectionPlugin.h"

namespace pd {
	D3D12RendererAPI* __stdcall InitDevice(DeviceParams params){ return nullptr; };
	EyeTextures __stdcall InitReprojection(InitParams params){ return EyeTextures(); };
	void __stdcall EvaluateReprojection(EvaluateParams& params){};
}
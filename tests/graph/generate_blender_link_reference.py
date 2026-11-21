"""Compile Blender's actual curve functions to generate port parity fixtures.
Usage: python3 tests/graph/generate_blender_link_reference.py ../blender
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
draw = (root / 'source/blender/editors/space_node/drawnode.cc').read_text()
shader = (root / 'source/blender/gpu/shaders/gpu_shader_nodelink.bsl.hh').read_text()
handles = draw[draw.index('static void calculate_inner_link_bezier_points('):draw.index('static std::array<float2, 4> node_link_bezier_points(')]
handles = handles.replace('const int curving = ui::theme::get_value_type(TH_NODE_CURVING, SPACE_NODE);', 'const int curving = test_curving;')
start = shader.index('  float t2 = t * t;')
end = shader.index('  float2 normal =', start)
evaluation = shader[start:end]
cpp = r'''
#include <array>
#include <cmath>
#include <algorithm>
#include <iostream>
#include <iomanip>
struct float2 {float x, y;};
float2 operator+(float2 a, float2 b) {return {a.x+b.x,a.y+b.y};}
float2 operator-(float2 a, float2 b) {return {a.x-b.x,a.y-b.y};}
float2 operator*(float2 a, float b) {return {a.x*b,a.y*b};}
bool is_zero(float2 a) {return a.x==0 && a.y==0;}
float2 normalize(float2 a) {float l=std::hypot(a.x,a.y);return l>0?a*(1/l):float2{0,0};}
namespace math {
float2 interpolate(float2 a,float2 b,float t){return a*(1-t)+b*t;}
float distance(float a,float b){return std::abs(a-b);}
float safe_divide(float a,float b){return b==0?0:a/b;}
float min(float a,float b){return std::min(a,b);}
}
int test_curving;
''' + handles + '\nvoid eval(std::array<float2,4> p,float t){\nauto P0=p[0], P1=p[1], P2=p[2], P3=p[3];\n' + evaluation + r'''
std::cout << "[" << point.x << "," << point.y << "," << tangent.x << "," << tangent.y << "]";
}
int main(){
std::cout << std::setprecision(9) << "[";
bool first=true;
for(int c: {0,1,4,10}) for(float2 b: {float2{410,120},float2{410,320},float2{-290,120},float2{-290,20},float2{10,320},float2{10,20},float2{20,21}}){
if(!first)std::cout<<",";first=false;
test_curving=c; std::array<float2,4> p; p[0]={10,20};p[3]=b;
calculate_inner_link_bezier_points(p);
std::cout<<"{\"curving\":"<<c<<",\"controls\":[";
for(int i=0;i<4;i++){if(i)std::cout<<",";std::cout<<"["<<p[i].x<<","<<p[i].y<<"]";}
std::cout<<"],\"samples\":[";
for(int i=0;i<5;i++){if(i)std::cout<<",";eval(p,i/4.0f);}
std::cout<<"]}";
}
std::cout<<"]";
}
'''
with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / 'reference.cc'
    exe = Path(tmp) / 'reference'
    src.write_text(cpp)
    subprocess.run(['c++', '-std=c++17', str(src), '-o', str(exe)], check=True)
    cases = json.loads(subprocess.check_output([str(exe)]))
revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
output = Path(__file__).resolve().parents[1] / 'fixtures/blender_link_reference.json'
output.write_text(json.dumps({'revision': revision, 'cases': cases}, indent=2) + '\n')
print(f'{len(cases)} reference cases from Blender {revision}')

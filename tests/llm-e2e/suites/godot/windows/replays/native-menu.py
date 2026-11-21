"""Capture an owned Win32 menu and dismiss only that menu's owner."""
import ctypes,json,sys,time
from ctypes import wintypes as w
from pathlib import Path
from PIL import ImageGrab
pid=int(sys.argv[1]);out=Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True)
selection=Path(sys.argv[3]) if len(sys.argv)>3 and sys.argv[3]!='--escape' else None
u=ctypes.WinDLL('user32',use_last_error=True)
u.SetProcessDpiAwarenessContext.argtypes=[w.HANDLE];u.SetProcessDpiAwarenessContext(w.HANDLE(-4))
callback=ctypes.WINFUNCTYPE(w.BOOL,w.HWND,w.LPARAM)
u.EnumWindows.argtypes=[callback,w.LPARAM]
u.GetWindowThreadProcessId.argtypes=[w.HWND,ctypes.POINTER(w.DWORD)]
u.GetClassNameW.argtypes=[w.HWND,w.LPWSTR,ctypes.c_int]
u.IsWindowVisible.argtypes=[w.HWND]
u.GetWindowRect.argtypes=[w.HWND,ctypes.POINTER(w.RECT)]
u.SendMessageW.argtypes=[w.HWND,w.UINT,w.WPARAM,w.LPARAM];u.SendMessageW.restype=w.LPARAM
u.PostMessageW.argtypes=[w.HWND,w.UINT,w.WPARAM,w.LPARAM]
u.GetMenuItemCount.argtypes=[w.HMENU]
u.GetMenuStringW.argtypes=[w.HMENU,w.UINT,w.LPWSTR,ctypes.c_int,w.UINT]
u.GetMenuState.argtypes=[w.HMENU,w.UINT,w.UINT]
u.GetMenuItemRect.argtypes=[w.HWND,w.HMENU,w.UINT,ctypes.POINTER(w.RECT)]
windows=[]
@callback
def collect(hwnd,_):
 owner=w.DWORD();u.GetWindowThreadProcessId(hwnd,ctypes.byref(owner))
 if owner.value==pid and u.IsWindowVisible(hwnd):
  name=ctypes.create_unicode_buffer(256);u.GetClassNameW(hwnd,name,256);windows.append((hwnd,name.value))
 return True
limit=time.monotonic()+15
while time.monotonic()<limit:
 windows.clear();u.EnumWindows(collect,0)
 menu=next((hwnd for hwnd,name in windows if name=='#32768'),None)
 if menu:break
 time.sleep(.03)
else:raise SystemExit('No owned native popup appeared')
# Windows animates native popup opacity after HWND creation.
time.sleep(0.35)
handle=u.SendMessageW(menu,0x1E1,0,0)
items=[]
for i in range(u.GetMenuItemCount(handle)):
 label=ctypes.create_unicode_buffer(512);u.GetMenuStringW(handle,i,label,512,0x400)
 items.append({'text':label.value,'checked':bool(u.GetMenuState(handle,i,0x400)&8)})
rect=w.RECT();u.GetWindowRect(menu,ctypes.byref(rect))
ImageGrab.grab(bbox=(rect.left,rect.top,rect.right,rect.bottom),all_screens=True).save(out/'native-view-menu.png')
result={'pid':pid,'items':items,'captured':True,'rect':[rect.left,rect.top,rect.right,rect.bottom]}
try:
 if selection:
  spec=json.loads(selection.read_text(encoding='utf-8'))
  index=spec['index'];item=w.RECT()
  assert 0<=index<len(items) and u.GetMenuItemRect(None,handle,index,ctypes.byref(item)), 'Missing requested native menu item'
  assert not u.GetMenuState(handle,index,0x400)&3, 'Requested native menu item is disabled'
  owner=next(hwnd for hwnd,name in windows if name!='#32768')
  # Drive the native modal loop with targeted keyboard messages. Menu mouse
  # messages use modal-loop screen coordinates, unlike ordinary client input.
  u.PostMessageW(owner,0x100,0x24,0)  # Home
  time.sleep(.05)
  for _ in range(len(items)+1):
   if u.GetMenuState(handle,index,0x400)&0x80:break
   u.PostMessageW(owner,0x100,0x28,0)  # Down
   time.sleep(.05)
  else:raise AssertionError('Native menu never highlighted requested item')
  u.PostMessageW(owner,0x100,0x0D,0)  # Enter
  result['selected_index']=index
  result['item_rect']=[item.left,item.top,item.right,item.bottom]
 else:
  for hwnd,name in windows:
   if name!='#32768':
    if '--escape' in sys.argv:u.PostMessageW(hwnd,0x100,0x1B,0)
    else:u.PostMessageW(hwnd,0x1F,0,0)
except Exception as error:
 result['error']=str(error)
 for hwnd,name in windows:
  if name!='#32768':u.PostMessageW(hwnd,0x1F,0,0)
(out/'native-menu.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')

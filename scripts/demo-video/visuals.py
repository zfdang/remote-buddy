"""Cartoon demo frames, current app screenshots, and shared subtitle layout."""
from pathlib import Path
import json
import math
import re
from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[2]
SCENES = json.loads(Path(__file__).with_name("storyboard.json").read_text())
W, H, FPS = 1920, 1080, 12
FONT = "/System/Library/Fonts/STHeiti Medium.ttc"
BLUE, INK, GREEN = "#3268DA", "#253449", "#258968"
ORANGE, BG, LINE = "#C67A2D", "#FFF9EF", "#DCE3EE"
fonts = {}
action_times = {}
scene_lengths = []


def get_font(size):
    if size not in fonts:
        fonts[size] = ImageFont.truetype(FONT, size)
    return fonts[size]


def text(d, xy, value, size=36, fill=INK):
    d.text(xy, value, font=get_font(size), fill=fill)


def rr(d, box, fill, r=28, outline=None, width=2):
    d.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


def center(d, x, y, value, size=36, color=INK):
    width = d.textlength(value, font=get_font(size))
    text(d, (x-width/2, y), value, size, color)


def wrap(d, value, size, max_width):
    lines, line = [], ""
    for char in value:
        if line and d.textlength(line+char, font=get_font(size)) > max_width:
            lines.append(line)
            line = char
        else:
            line += char
    if line:
        lines.append(line)
    return lines


def character(d,x,y,t):
 # Friendly cartoon operator, drawn directly for this animation.
 bob=math.sin(t*2.4)*4
 y+=bob
 d.ellipse((x-92,y-78,x+92,y+114),fill='#E6BE98',outline=INK,width=4)
 d.pieslice((x-94,y-100,x+94,y+73),180,360,fill='#364358')
 d.ellipse((x-51,y+1,x-35,y+22),fill=INK);d.ellipse((x+32,y+1,x+48,y+22),fill=INK)
 d.ellipse((x-77,y+40,x-49,y+52),fill='#E8998D');d.ellipse((x+48,y+40,x+76,y+52),fill='#E8998D')
 d.arc((x-29,y+18,x+29,y+64),5,175,fill=INK,width=5)
 rr(d,(x-122,y+112,x+122,y+320),BLUE,60)
 d.line((x-84,y+170,x-150,y+232),fill='#E6BE98',width=36)
 d.line((x+82,y+170,x+156,y+112),fill='#E6BE98',width=36)
 d.ellipse((x+130,y+88,x+174,y+131),fill='#E6BE98',outline=INK,width=3)
 center(d,x,y+165,'RB',48,'white')

def remote(d,x,y,t,active=False,scale=1):
 rw,rh=int(112*scale),int(310*scale)
 if scale != 1:
  layer=Image.new('RGBA',(112,310),(0,0,0,0))
  remote(ImageDraw.Draw(layer),0,0,t,active,1)
  layer=layer.resize((rw,rh),Image.Resampling.LANCZOS)
  d._image.paste(layer,(int(x),int(y)),layer)
  return
 rr(d,(x,y,x+rw,y+rh),'#344256',30)
 for px in [.31,.70]: d.ellipse((x+rw*px-10,y+28,x+rw*px+10,y+48),fill='#647489')
 if active:
  d.ellipse((x+rw*.70-16,y+22,x+rw*.70+16,y+54),outline=GREEN,width=5)
 d.ellipse((x+rw*.18,y+65,x+rw*.82,y+139),fill='#1F2C40')
 d.ellipse((x+rw*.38,y+89,x+rw*.62,y+114),fill='#728296')
 for row in range(3):
  for px in [.32,.68]:d.ellipse((x+rw*px-10,y+161+row*39,x+rw*px+10,y+181+row*39),fill='#728296')
 center(d,x+rw/2,y+rh-26,'RB',24,'#AAB8CA')



screenshots = {}


def screenshot(im, d, filename, label):
    if filename not in screenshots:
        shot = Image.open(ROOT / "pages/assets/screenshots" / filename).convert("RGB")
        # Focus on the current content area; omit the narrow navigation column.
        # The full-size examples remain available in the webpage gallery.
        shot = shot.crop((216, 0, shot.width, min(shot.height, 1120)))
        screenshots[filename] = ImageOps.contain(shot, (950, 530), Image.Resampling.LANCZOS)
    shot = screenshots[filename]
    rr(d, (830, 290, 1840, 860), "white", 24, LINE)
    im.paste(shot, (int(1335-shot.width/2), int(565-shot.height/2)))
    text(d, (858, 821), label + " · 当前界面示例", 22, "#68758A")


def card(d, y, heading, detail, color=BLUE):
    rr(d, (860, y, 1810, y+125), "white", 22, LINE)
    text(d, (890, y+19), heading, 32, color)
    for k, line in enumerate(wrap(d, detail, 25, 860)):
        text(d, (890, y+68+k*31), line, 25, "#68758A")


def frame(index, progress, total, duration, subtitle=""):
    scene = SCENES[index]
    kind = scene["id"]
    t = progress * 12
    local = progress * (scene_lengths[index] if scene_lengths else 20)
    actions = action_times.get(kind, {})
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    text(d, (76, 42), "REMOTE BUDDY  /  遥控搭子", 27, BLUE)
    text(d, (76, 105), scene["title"], 60)
    text(d, (78, 191), scene["subtitle"], 32, "#68758A")
    rr(d, (76, 278, 795, 862), "#EDF3FC", 30)
    operator = Image.new("RGBA", (360, 450), (0, 0, 0, 0))
    character(ImageDraw.Draw(operator), 180, 105, t)
    operator = operator.resize((252, 315), Image.Resampling.LANCZOS)
    im.paste(operator, (100, 520), operator)
    for j, bullet in enumerate(scene["bullets"]):
        y = 320+j*150
        d.ellipse((365, y+4, 400, y+39), fill=GREEN)
        center(d, 382, y+4, str(j+1), 24, "white")
        for k, line in enumerate(wrap(d, bullet, 30, 335)):
            text(d, (421, y+k*43), line, 30)

    if kind == "intro":
        remote(d, 907, 355, t, 0.25 < progress < 0.75, 1.25)
        rr(d, (1100, 350, 1820, 730), "white", 28, LINE)
        center(d, 1460, 393, "Remote Buddy", 48, BLUE)
        center(d, 1460, 478, "遥控器 → Mac → 输入工具", 32)
        center(d, 1460, 570, "让语音输入的入口就在手边", 30, GREEN)
        center(d, 1460, 645, "支持范围以设备指南为准", 25, "#68758A")
    elif kind == "flow":
        for j, (name, detail) in enumerate([
            ("遥控器", "声音 + 按键"), ("遥控搭子", "音频 + 语音热键"), ("输入工具", "识别 + 写入文字")
        ]):
            x = 840+j*337
            rr(d, (x, 385, x+300, 640), "white", 24, LINE)
            center(d, x+150, 436, name, 36, BLUE)
            center(d, x+150, 538, detail, 26)
            if j < 2:
                text(d, (x+305, 490), "→", 27, GREEN)
        center(d, 1340, 725, "Remote Buddy Mic 是连接两者的虚拟麦克风", 27, GREEN)
    elif kind == "install":
        card(d, 325, "官网下载适合 Mac 芯片的安装包", "Apple Silicon / Intel · macOS 14+")
        card(d, 485, "Remote Buddy.app + 虚拟麦克风驱动", "安装后打开应用，按向导检查环境")
        card(d, 645, "在输入工具中选择麦克风", "麦克风：Remote Buddy Mic", GREEN)
    elif kind == "devices":
        rows = [
            ("小米 2 Pro · RC003", "语音与按键已验证；2 代 RC001 完整音频待验收", GREEN),
            ("T1 飞鼠键盘遥控器", "已测蓝牙样机支持；兼容批次需单独验证", GREEN),
            ("Chromecast · G9N9N", "已验证版本支持语音与按键", GREEN),
        ]
        for j, row in enumerate(rows):
            card(d, 305+j*153, *row)
        center(d, 1335, 800, "GY3LE / Siri Remote：计划支持，尚未完成适配", 25, "#68758A")
    elif kind in ("xiaomi", "t1"):
        is_t1 = kind == "t1"
        start, stop = actions.get("start", 4), actions.get("stop", 8)
        recording = start <= local < stop
        held = recording if not is_t1 else (start <= local < start+.35 or stop <= local < stop+.35)
        title = "T1 · 已测样机操作示意" if is_t1 else "小米 2 Pro · 操作示意"
        center(d, 1465, 325, title, 32, BLUE)
        phase = 0 if local < start else 1 if local < stop else 2
        steps = ["准备输入", "已松手，持续收音" if is_t1 else "保持按住，正在收音", "再次点按，停止收音" if is_t1 else "松开按键，停止收音"]
        rr(d, (1120, 395, 1810, 565), "white", 22, LINE)
        center(d, 1465, 425, steps[phase], 32, GREEN if recording else BLUE)
        center(d, 1465, 500, "声音送入 Remote Buddy Mic", 26, "#68758A")
        remote(d, 884, 414, t, held, 1.05)
        for j in range(32):
            amplitude = 8+24*abs(math.sin(j*0.7+t*3)) if recording else 3
            x = 1160+j*18
            d.line((x, 652-amplitude, x, 652+amplitude), fill=GREEN, width=7)
        center(d, 1460, 727, "T1：点按开始 / 再按结束" if is_t1 else "小米：按住开始 / 松手结束", 29)
        center(d, 1460, 788, "结束后等待尾音和输入工具处理", 25, "#68758A")
    elif kind in ("permissions", "tools", "mapping"):
        filename = scene["screenshot"]
        if kind == "mapping" and progress > 0.55:
            filename = "phrases-zh.png"
        screenshot(im, d, filename, {"permissions": "权限与麦克风", "tools": "输入法集成", "mapping": "按键映射 / 常用语"}[kind])
    elif kind == "privacy":
        card(d, 325, "遥控搭子", "不保存录音或转写历史，不采集使用统计", GREEN)
        card(d, 485, "本地运行日志", "不上传日志，可由用户在本机查看", GREEN)
        card(d, 645, "你选择的识别工具", "联网和音频处理方式，请查看该工具的设置与隐私政策", BLUE)
    elif kind == "example":
        rr(d, (850, 315, 1830, 800), "white", 28, LINE)
        text(d, (890, 350), "编辑器 / 聊天窗口 / 终端 · 输入流程示意", 28, BLUE)
        rr(d, (886, 420, 1795, 660), "#F2F6FD", 18)
        phrase = "把这段逻辑重构为异步并发，并增加测试。"
        stop = actions.get("stop", 11)
        count = max(0, min(len(phrase), int((local-stop-1)*len(phrase)/3)))
        value = phrase[:count] if count else "先点击准备输入的位置…"
        for k, line in enumerate(wrap(d, value, 38, 830)):
            text(d, (917, 470+k*57), line, 38, INK if count else "#8793A5")
        center(d, 1340, 711, "准备输入" if local < actions.get("start", 5) else "说话 → 结束收音 → 等待识别" if local < stop+1 else "检查输入工具返回的文字", 29, GREEN)
        center(d, 1340, 758, "处理速度与结果取决于所选输入工具", 23, "#68758A")
    else:
        rr(d, (850, 315, 1830, 810), "white", 30, LINE)
        center(d, 1340, 360, "Remote Buddy · 遥控搭子", 44, BLUE)
        center(d, 1340, 465, "remote.zfdang.com", 54)
        center(d, 1340, 570, "下载应用 · 查看设备指南 · 完成语音测试", 29, GREEN)
        center(d, 1340, 682, "GPL-3.0-only 开源", 30)
        center(d, 1340, 745, "从一次语音测试开始", 26, "#68758A")

    text(d, (80, 875), "产品介绍与操作示意 · 界面示例不代表硬件验收", 21, "#68758A")
    text(d, (1690, 875), f"{index+1:02d} / {len(SCENES):02d}", 23, "#68758A")
    rr(d, (76, 920, 1844, 1045), INK, 22)
    lines = wrap(d, subtitle, 35, 1650)
    if len(lines) > 2:
        raise ValueError(f"Subtitle exceeds two lines: {subtitle}")
    for k, line in enumerate(lines):
        center(d, W/2, 950+k*45 if len(lines) > 1 else 963, line, 35, "white")
    rr(d, (76, 1064, 1844, 1072), LINE, 4)
    rr(d, (76, 1064, 76+1768*min(1, total/duration), 1072), BLUE, 4)
    return im


def subtitle_chunks(narration):
    pieces = re.findall(r"[^，。！？；]+[，。！？；]?", narration)
    chunks, current = [], ""
    for piece in pieces:
        if len(current+piece) > 36 and current:
            chunks.append(current)
            current = ""
        while len(piece) > 36:
            if current:
                chunks.append(current)
                current = ""
            chunks.append(piece[:36])
            piece = piece[36:]
        current += piece
        if piece.endswith(("。", "！", "？")):
            chunks.append(current)
            current = ""
    if current:
        chunks.append(current)
    combined = []
    for chunk in chunks:
        if combined and not any(char.isalnum() for char in chunk):
            combined[-1] += chunk
        else:
            combined.append(chunk)
    return combined


def stamp(seconds):
    ms = round(seconds*1000)
    return f"{ms//3600000:02}:{ms//60000%60:02}:{ms//1000%60:02}.{ms%1000:03}"

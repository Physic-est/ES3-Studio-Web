--##############################################################################
-- Extra-Slide v3 - 3Dレーンモード
--
-- Slide譜面を独自の3Dレーンで遊ぶ Free Mode スキン。
-- 全要素(床・ノーツ・帯・空中要素・演出)を Lua 側の手動投影 T3DProject() で描くので、
-- カメラ(Cam)を書き換えるだけで画面全体が一斉に追従する。
--
-- 構成:
--   投影/逆射影   T3DProject / T3DUnproject / T3DSetQuad / T3DSetBand / T3DSetBand3
--   カメラ        Cam / T3DApplyTrackAngle（判定線を固定したまま傾きを変える）
--                 譜面からの演出は拡張ファイルの cam 行 -> T3DCommitCam -> T3DUpdateCam
--   床            T3DBuildFloor / T3DUpdateFloor / OnDrawNote / OnNoteMove
--   空中要素      拡張ファイル(lane3d.ex) -> T3DParseAir -> T3DCommitAir(規約チェック) -> T3DUpdateAir
--   判定          T3DJudgeFloorPress / T3DJudgeAirPress / T3DUpdateHolds / T3DUpdateAirJudge
--   入力          タッチ(OnInput) もキー(OnKey) も「ポインタ」に変換して同じ判定に通す。
--                 当たりは床・空中とも「ポインタの位置が要素の幅の中か」
--   演出          TapEffect / 判定表示 / Hold 中エフェクト
--
-- ログ（log/*.log に "LUA:" 付きで出る）:
--   Init 内の例外はゲームに握り潰され "[ScenePlay] load error" しか出ないので、
--   起動時は各段階を "[T3D] step: xxx OK / FAILED" で出す。どこで止まったかがここで分かる。
--   毎フレームの処理で起きたエラーは "[T3D] エラー(xxx)" で出る（最初の30件）。
--##############################################################################

print('[T3D] chunk loaded')

--------------------------------------------------------------------------------
-- 設定
--------------------------------------------------------------------------------
local T3D = {
  Floor      = true,   -- 床（レーン・判定線・左右バー・空中判定線）
  Judge      = true,   -- 判定とスコア
  HitFx      = true,   -- TapEffect
  JudgeText  = true,   -- BEST/COOL/GOOD/MISS の判定表示
  HoldFx     = true,   -- Hold 中のエフェクト
  Flick      = true,   -- フリックの矢印
  Air        = true,   -- 空中要素（AirSlide・AirTap）
  Trace      = true,   -- トレース（拡張ファイルの trace / guide 行。判定の無い飾り）
  Measure    = true,   -- 小節線
  Cam        = true,   -- 拡張ファイルの cam 行によるカメラ演出
  Fx         = true,   -- 画面演出（拡張ファイルの fx 行・Miss の赤い縁・コンボの拡大）
  PerfLog    = false,  -- 5秒ごとにフレーム時間とノーツ数をログに出す（重さの調査用）
  BandCap    = 384,    -- 1本の Slide が持つ帯の Grid の上限。中継点が何千もある Slide が出てくる瞬間に、
                       -- Grid を作りすぎて止まるのを防ぐ。見えている帯が上限を超えたら、奥の分は描かない
  LegacySlide = false, -- 時刻が戻る Slide（敷）を旧 Malody の描き方で描く（Beta）。設定 LegacyMode (Beta) で Init 時に決まる
}

-- 塗り潰し用の素材。このスキン用に追加した 32x32 の白（Composer に登録しなくても読める）
local T3DTex    = 'white.png'

-- v2 から引き継ぐ 2D 素材
local TexTap    = 'slide-legacy-note-tap.png'    -- 243x170
local TexWipe   = 'slide-legacy-note-wipe.png'   -- 243x170
local TexLong   = 'slide-legacy-note-long.png'   -- 120x32
local TexJudge  = 'slide-legacy-track-judge.png' -- 182x46
local TexTrack  = 'slide-legacy-track-bar.png'   -- 62x1080
-- slide-legacy-light-* は加算合成用でアルファが全面255・背景が純黒。
-- 通常のアルファ合成で描くと黒い矩形が出るので、
-- 「明るさ->アルファ / 色は最大輝度に正規化」で変換した fx-light-* を使う
local HitFxConf = {
  Tex     = 'fx-light-',   -- 0〜15 の16コマ(384x384, アルファ付き)
  Frames  = 16,
  FrameMs = 26,            -- 1コマあたり(ms)。16コマで約420ms
  Slots   = 6,             -- 同時に出せるTapEffectの数
  Size    = 1.05,          -- レーン幅に対するTapEffectの大きさ
}

-- 判定表示（v2 の slide-legacy-judge-{best,cool,good,miss}-0〜19。アルファ付きでそのまま使える）
local JudgeTextConf = {
  Tex     = 'slide-legacy-judge-',
  Names   = { 'best', 'cool', 'good', 'miss' },   -- JudgeType の番号順
  -- 元素材は20コマだが、4〜16コマ目はほぼ同じ絵（13コマで差が2.6しかない）だった。
  -- 静止部分を代表1枚に畳んで 8コマにし、その1枚を長く出して見た目を保つ。
  -- アトラスに入る画像が 80枚 -> 32枚 に減る（judge だけで 480x180 が48枚減る）
  Frames  = 8,
  -- コマごとの長さ(ms)。合計は元と同じ約560ms。
  -- 内訳: 入り4枚 / 静止の代表1枚（元の13コマぶん）/ 抜け3枚
  FrameMs = { 28, 28, 28, 28, 364, 28, 28, 28 },
  -- 表示位置は空中判定線の上に自動で取る（SkyLineConf.ScreenOffset を変えても重ならない）。
  -- Gap は空中判定線から判定表示の下端までの間隔
  Gap     = 34,
  Scale   = 0.85,   -- 素材 480x180 に対する倍率
}

-- Hold 中のエフェクト。v2 の Effect-Hold 素材は TapEffect の後半コマと同一なので、
-- 変換済みの fx-light のうち明るい区間(5〜11)をループさせる
local HoldFxConf = {
  First   = 5,
  Count   = 7,
  FrameMs = 40,
  Slots   = 4,      -- 同時に押し続けられる Hold の数
  Size    = 0.8,    -- レーン幅比
}

-- フリック矢印。Tap系は flick-arrow-1〜3、Wipe系は 4〜6。いずれも 1=左 2=上 3=右
local FlickConf = {
  Tex       = 'flick-arrow-',
  Size      = 0.42,   -- レーン幅比
  Lift      = 90,     -- 床からの高さ(ワールド単位)
  Dist      = 80,     -- フリック成立に必要な移動量（画面単位）
  TimeoutMs = 250,    -- 押してからフリックし終えるまでの制限時間
}
local T3DLanes  = 4       -- 床のレーン数
local T3DSlices = 6       -- 奥行き方向の分割数
local T3DTrackW = 1100    -- 判定線上でのトラック幅(ワールド単位)
local T3DDepth  = 4000    -- 床の奥行き(ワールド単位)
local T3DNoteDepth = 130  -- ノーツ1枚の奥行き(ワールド単位)

-- 空中要素（AirSlide / AirTap）
local T3DHeightMax = 280   -- 拡張ファイルの y=255 に対応するワールド高さ。ここに空中判定線を引く
-- Roll（画面の傾き）の回転軸をどこに置くか。横は常にレーンの中心（パンに追従）。
-- 縦は下のどれか。光学中心(0, Cam.ShiftY)は角度35で -795＝画面外はるか下にあるので使わない
-- （少し傾けただけでレーン全体が大きく振り回される）。
--
--   'lane'   レーンの上下中央。**180度でその場で上下反転する**（既定）
--   'sky'    空中判定線の高さ
--   'judge'  床の判定線
--   'center' 画面中央(0)
--   数値     その画面Y を直接指定
--
-- 角度35・ズーム1のときの目安: 床の手前端 -580 / 判定線 -352 / 空中判定線 -52 /
-- ノーツ出現(z=4000) +248 / 床の奥端 +294。画面は -540〜+540
local RollPivot = 500
local T3DRollPivotX = 0
local T3DRollPivotY = -166
-- 空中判定線
local SkyLineConf = {
  HalfT    = 6,      -- 太さ（画面上。投影スケールが掛かる）
  Alpha    = 80,     -- 不透明度
  -- 「床の判定線から画面上で何ユニット上か」で指定し、高さは逆算する。
  -- 高さで指定すると、傾きを変えたときに画面上の位置が大きく動いてしまう
  -- 経緯: 434=良い / 474=高すぎ / 170=低すぎ
  ScreenOffset = 300,
  -- 普段は消しておき、空中要素が来る前に短く点滅してから点灯させる
  ShowMs   = 700,    -- 空中要素の何ms前から点灯させるか
  BlinkMs  = 600,    -- 点灯の前に点滅する長さ
  BlinkMs1 = 60,     -- 点滅1回ぶんの長さ（小さいほど速い）
  HideMs   = 700,    -- 最後の空中要素から何ms後に消し始めるか
  FadeMs   = 350,    -- 消えるときのフェードアウトの長さ
  -- これより近い空中要素どうしはひと続きに扱う（消えてすぐ出るのを防ぐ）。
  -- 点滅〜消え終わりの合計 (Show+Blink+Hide+Fade) より大きくしておくこと
  MergeMs  = 2500,
}
local AirConf = {
  FileNames        = { 'lane3d.ex', 'chart_3d.ex' },
  SlideSamples     = 14,   -- AirSlide1本の分割数。多いほど滑らかだが重い
  SlidePool        = 20,   -- 同時に描けるAirSlideの本数
  -- AirSlide は幅のある平らな半透明の板＋明るい縁取り。ワールド空間で水平な帯なので、
  -- 床と同じように遠近で潰れて「空間に置かれた面」に見える
  SlideEdgeW       = 9,    -- 縁取りの半幅（ワールド単位）
  SlideFillAlpha   = 30,   -- 板の不透明度
  SlideEdgeAlpha   = 92,   -- 縁取りの不透明度
  SlideShadowAlpha = 18,   -- 影の濃さ（板が平たいので控えめ）
  TapShadowAlpha   = 34,   -- AirTap の影の濃さ
  TapPool          = 14,   -- 同時に描けるAirTapの数
  OverlapX         = 20,   -- AirTap が AirSlide に「重なっている」とみなす横位置の差
  DefaultWidth     = 64,   -- 拡張ファイルで幅を省略したときの空中要素の幅（譜面 x 単位）
  StartGraceMs     = 150,  -- AirSlide・床の Hold/Slide の開始から、取り始めが間に合う猶予
}

-- トレース（判定の無い飾り）。拡張ファイルの
--   trace,開始ms,終了ms,x1,x2,y1,y2[,ease]                       線（空中・床のどこでも）
--   guide,開始ms,終了ms,x1,x2,幅1,幅2[,ease[,不透明度]][,#rrggbb]  床の帯
-- 判定・配点・空中判定線の点灯には関わらない。判定線を越えた分は消える（床の Slide と同じ）
local TraceConf = {
  -- 1区間の分割数（ease の曲線をなめらかにする）。奥行きは両端の仮想ノーツから時刻に比例して埋めるので、
  -- 区間の途中で譜面の scroll が変わっても途中の点は追わない（区間を短く分けて書けば追う）。timinggroup のグループは全点を追う
  Samples     = 8,
  LinePool    = 24,    -- 同時に描ける trace の区間数
  GuidePool   = 16,    -- 同時に描ける guide の区間数
  LineHalf    = 3,     -- trace の半分の太さ（ワールド単位。遠近で細くなる）
  LineMinPx   = 1.2,   -- 奥でも消えないよう、画面上の半分の太さはこれより細くしない
  LineColor   = { 120, 120, 132 },
  LineAlpha   = 50,
  -- 空中にある trace の真下の床に落とす影。黒だと暗い床に溶けて見えないので、床より明るい灰色の細い線にする。
  -- 線と影の離れ方で高さが分かる
  ShadowColor = { 70, 72, 88 },
  ShadowAlpha = 10,
  -- 判定線の位置（奥行き 0）を線が通る点に出す光の点。点が上下に動くので、線の高さの変化が分かる
  DotTex      = 'trace-dot.png',
  DotHalf     = 16,    -- 点の半分の大きさ（ワールド単位）
  DotAlpha    = 95,
  DotOrder    = 770,
  LineOrder   = 680,   -- 奥ほど小さくする（AirSlide より少し奥）
  GuideAlpha  = 30,    -- guide の不透明度の既定
  GuideColor  = { 90, 230, 160 },
  GuideOrder  = 15,    -- 小節線(12)より手前、影(16)・左右のバーより奥
}
-- raw … 読込中の行 / lines・guides … 時刻順の区間 / linePool・guidePool … 描画用の Grid（行のある種類だけ作る）
-- colors … 色 -> 番号（T3DSetTint の key 用）/ bufX・bufY・bufZ … 毎フレーム使い回す点の列
local Trace = {
  raw = {}, lines = {}, guides = {}, linePool = {}, guidePool = {}, colors = {}, colorN = 0,
  bufX = {}, bufY = {}, bufZ = {}, on = false, overLogged = false,
  lineFirst = 1, guideFirst = 1, lastNow = 0,   -- 通り過ぎた区間を飛ばす位置（時刻が戻ったら 1 から）
}

-- カメラ。ここを書き換えるだけで床・ノーツ・空中要素が一斉に追従する。
--   X      : 横位置（パン）
--   Y      : 高さ
--   Z      : 判定線からの距離（ドリー）
--   Pitch  : 俯角(度)
--   Roll   : 画面の傾き(度)
--   Focal  : 焦点距離（ズーム）
--   ShiftY : 画面上の上下オフセット（判定線の位置合わせ用。演出には使わない）
local Cam = { X = 0, Y = 320, Z = 620, Pitch = 32, Roll = 0, Focal = 950, ShiftY = -430 }

-- 譜面からのカメラ演出。拡張ファイルの
--   cam,開始ms,終了ms,項目,開始値,終了値[,ease]
-- を項目ごとに時刻順へ並べ、毎フレーム補間して Cam に流し込む。
-- 項目は書き換えるまで既定値のまま。区間の後は終了値を保つ（元には戻らない）。
--   angle 傾き(度)      既定 T3DTrackAngle。判定線の位置と幅は固定したまま傾く
--   x     横位置        譜面x(0〜255)。既定 128 = レーンの中心
--   y     カメラの高さ  ワールド単位。既定 320
--   z     カメラの距離  ワールド単位。既定 620。小さいほど判定線に寄る
--   roll  画面の傾き(度) 既定 0
--   zoom  ズーム倍率    既定 1。判定線の画面位置は変えずにトラックの見かけの幅が変わる
local CamRange = {
  angle = { 5, 85 },
  x     = { -255, 510 },
  y     = { 40, 2000 },
  z     = { 120, 4000 },
  roll  = { -360, 360 },
  zoom  = { 0.2, 5 },
  -- Roll の回転軸の画面Y。書かなければスキンの RollPivot 設定に従う
  rollpivot = { -3000, 3000 },
}
local CamBase    = { angle = 35, x = 128, y = 320, z = 620, roll = 0, zoom = 1, rollpivot = -166 }
local T3DCamEvents = {}     -- 項目 -> { {s, e, v1, v2, ease}, ... }（時刻順）
local T3DCamIndex  = {}     -- 項目 -> 今見ている区間。時刻はほぼ単調に進むので前後に1つずつ動かす
local T3DCamOn     = false  -- cam 行が1つでもあれば true。無ければ毎フレームの処理をまるごと省く

-- レーンの傾き。Malody の「3Dトラック角度」と同じ意味（0=正面 / 90=真横）で、
-- カメラの俯角は 90 - 角度。小さいほど寝て、奥が画面の上まで伸びる。
-- 本体の FieldMeta('Angle') は譜面側の値が返ることがあり（config が 45 でも 50 が来た）、
-- スキンの見た目を決める値としては当てにならないので、既定ではスキン側の定数を使う。
-- 傾きを変えても判定線の画面上の位置と幅は固定し、Focal と ShiftY を逆算する
local T3DTrackAngleBase = 35     -- レーンの傾き(度)の既定値。カスタム設定 Lane Angle が 0 以下ならこれ
local T3DTrackAngle     = 35     -- 実際に使うレーンの傾き(度)。T3DLoadSettings で決まる
local T3DTrackAngleUsed = 35     -- 実際に使った角度（Init で決まる）。cam の angle の既定値になる
local UseFieldAngle     = false  -- true なら FieldMeta('Angle') を優先する
local JudgeScreenY      = -352   -- 判定線中心の画面Y
-- 判定幅の倍率(JudgeScale)とは別物。名前がぶつかるとカメラが壊れるので JudgeLine を付けている
local JudgeLineScale    = 1.366  -- 判定線上の投影スケール（トラック幅の見え方）
local JudgeLineHalfZ    = 52     -- 判定線の奥行き方向の半分の厚み(ワールド単位)
-- 判定線の端をバーの幅のどこまで伸ばすか。0 = レーン（黒い下地）の幅ぴったりで、
-- バーの手前で切れる。1 = バーの quad の外側まで（バーに乗る）
local JudgeLineReach    = 0

--------------------------------------------------------------------------------
-- カスタム設定（ゲーム内の設定画面に出る項目）
--   Composer でキーを定義し、Init で Module:GetNumber / GetBool で読む。
--   GetNumber は未定義なら 0、GetBool は未定義なら false が返るので、
--   数値は 0 以下を「既定値のまま」、スイッチは「Hide 〜」（false = 表示）にしてある。
--   Composer にキーが無くても今までどおりの見た目になる
--------------------------------------------------------------------------------
local SettingKeys = {
  LaneScale  = 'Lane Scale',          -- Number。レーンの拡大率(%)。100 = 等倍
  LaneAngle  = 'Lane Angle',          -- Number。レーンの傾き(度)。T3DTrackAngle を上書き
  HideHitFx  = 'Hide Tap Effect',     -- Bool
  HideHoldFx = 'Hide Hold Effect',    -- Bool
  HideJudge  = 'Hide Judge Text',     -- Bool
  HideBar    = 'Hide Measure Lines',  -- Bool
  HideAutoFx = 'Hide Auto FX',        -- Bool。Miss の赤い縁・コンボの拡大
  HideChartFx = 'Hide Chart FX',      -- Bool。譜面の fx 行（フラッシュ・揺れ・グリッチ等）
  LegacyMode = 'LegacyMode (Beta)',   -- Bool。旧 Malody の敷スライドを再現（既定 false。曲を開いたときだけ読む）
}
local LaneScaleRange = { 50, 200 }    -- %
local LaneAngleRange = { 10, 80 }     -- 度

-- レーンの拡大率（ユーザー設定）。判定線の画面位置は変えずにトラックの見かけの幅を変える。
-- 譜面の cam zoom とは掛け算になる（譜面 zoom 2 x 設定 80% = 1.6）
local UserZoom = 1
-- 今実際に使っている拡大率（UserZoom x 譜面の zoom）。T3DApplyTrackAngle が更新する。
-- 空中判定線の画面上の位置が変わるので、タッチの床/空中の境界と判定表示の位置もこれに合わせる
local T3DZoomNow = 1

-- 床の伸ばし方。手前は画面下端(FloorBottomY)に届く位置を逆算、奥は T3DDepth の先まで伸ばしてフェード
local FloorBottomY  = -580       -- 画面下端(-540)より少し下
local T3DFloorNear  = -250       -- 判定線より手前の端（T3DApplyTrackAngle で上書き）
local T3DFloorFar   = 6000       -- 奥の端。T3DDepth より先はフェードアウト

local GameWidth, GameHeight = 1920, 1080
local T3DGroup = nil
local T3DFloorQuads = {}
local T3DTrackBars = {}      -- トラック左右の発光バー
local T3DHitFx = {}          -- TapEffect のスロット
-- 判定表示。同時に1つだけ。frames[判定種別][コマ]
local T3DJudgeText = { frames = {}, kind = 0, start = -99999, cur = -1 }
local T3DHoldFx = {}         -- [slot] = { frames, kind, ref, start, cur }
local T3DFloorAlpha = 78     -- 床の不透明度
local T3DBarWidth = 50       -- 左右バーの幅(ワールド単位)

-- 小節線。譜面ファイルには小節の区切りが入っていないので、
-- 拡張ファイルの measure 行で「1本目の拍」と「1小節の拍数」を指定する（無ければ 0拍 / 4拍）
local MeasureConf = {
  Tex   = 'slide-legacy-beatbar.png',  -- 200x100。中央の10行だけが白(アルファ167)
  Alpha = 26,   -- 薄く出す
  HalfZ = 40,   -- 奥行きの半分の厚み。素材の見えている帯は 1/10 なので線はこの 0.2 倍
  Pool  = 10,   -- 同時に描ける本数
}
local MeasureStartBeat = 0    -- 1本目の小節線の拍（拡張ファイルの measure 行で上書き）
local MeasureBeats     = 4    -- 1小節の拍数（同上）
local T3DMeasureQuads  = {}
local T3DBpmTable      = nil  -- { time, bpm, beat } の配列。beat は曲頭からの累積拍
-- 描かないノーツ（まだ奥すぎる / 帯を通過し終わった）。nid -> true。
-- 毎フレーム子要素を消し直すと、遠くのノーツが多数派の今は無駄が大きいので、
-- 状態が変わった1回だけ消す。リトライで必ずリセットすること
local T3DHiddenNote = {}
local T3DAlive = false          -- Init が最後まで通ったか
local T3DInputLogged = 0        -- タッチ入力のログ件数

-- 床のキー（PC での確認用）。キーコード -> レーン番号。OnKey の Source() は ASCII と一致する
local T3DKeyLane = {
  [97]  = 1,  -- a
  [115] = 2,  -- s
  [100] = 3,  -- d
  [102] = 4,  -- f
}
local T3DLaneDown = { false, false, false, false }
local T3DLaneQuads = {}

-- 空中のキー（PC での確認用）。床と同じく4レーンの区間を持つ。キーコードは OnKey の Source() の値
local T3DAirKeyLane = {
  [113] = 1,  -- q
  [119] = 2,  -- w
  [101] = 3,  -- e
  [114] = 4,  -- r
}
local T3DAirLaneDown = { false, false, false, false }

-- 入力（タッチ前提。キーボードも同じ「ポインタ」として扱う）
local T3DPointers = {}        -- id -> { layer='floor'|'air', x, sx, sy, laneL, laneR, isKey, down, flick }
local T3DFlickPending = {}    -- フリックの方向入力待ちのノーツ。nid -> true
local T3DAuto = false         -- Play:IsAuto()
local T3DKeyLogged = 0
local InputConf = {
  -- HitY の原点。'bottom' = 画面下が 0（Unity の入力座標と同じ）。
  -- 2026-09-20 実機で確定: 'top' にしていたら上下が逆になり、床の判定が画面の上半分に来て
  -- 判定線付近を叩いても反応しなかった
  TouchYOrigin   = 'bottom',
  TouchTolerance = 14,    -- タッチの当たりの余裕（譜面 x 単位。レーン幅は約64）
  ReleaseGraceMs = 90,    -- Hold / AirSlide を一瞬離しても切れない猶予
  WipeLeadMs     = 20,    -- Wipe が判定時刻の何ms前から取れるか
}
-- 切れた Hold / Slide / AirSlide の見た目（触れ直すと元に戻る）。
-- 不透明度を下げるだけだと暗い床の上でほぼ見えなくなるので、灰色に寄せて不透明度は少しだけ下げる
local BrokenConf = {
  Dim = 0.7,                     -- 不透明度の倍率
  R = 120, G = 120, B = 135,     -- 色（乗算）
}

-- 空中要素のデータと描画プール
local T3DAirSlides = {}      -- { s, e, x1, y1, x2, y2, ease, w, state, judged, lostAt }
local T3DAirTaps = {}        -- { time, x, y, w, judged }
local T3DAirSlideQuads = {}    -- [本] = { fill = {}, edgeL = {}, edgeR = {}, shadow = {} }
local T3DAirTapQuads = {}    -- [個] = { note, shadow }
-- 読込中の空中要素。規約チェック(T3DCommitAir)を通ったものだけが T3DAirSlides / T3DAirTaps に入る
local T3DAirRaw = { slides = {}, taps = {} }
local T3DSkySpans = {}       -- 空中判定線を点灯させる区間 { s, e }。空中要素の時刻をまとめたもの
local T3DSkyIndex = 1        -- 今見ている区間。時刻はほぼ単調に進むので前後に1つずつ動かす
-- ノーツが「出現してから判定されるまで」の時間(ms)。エンジンの窓 W。
-- プレイヤーのスピード設定で変わるので、実際に流れているノーツから実測する。
-- これが無いと、エンジンの管理外にあるAirSlideを正しい奥行きに置けない。
-- エンジンの p は 1 - p = (Pos(ノーツ時刻) - Pos(今)) / W で、Pos は譜面の scroll の積分（jump 込み）。
-- 実測の (ノーツ時刻 - 今) / (1 - p) は scroll が 1 の間しか W にならないので、
-- **最初のノーツで1回だけ測って固定する**（譜面の頭は scroll 1 とみなす）。
-- Game:PlayMeta('speed') はスピード設定を変えても 1.0 のままで使えない（2026-09-27 TestCode32）
local T3DScrollWindow = 1500
local T3DScrollMeasured = false   -- 1回でも実測できたか

-- ノーツグループごとのスクロール速度（拡張ファイルの hs 行）。
-- グループは譜面データ側の値で、実行時は info.group で取れる。既定は全部 1 倍。
-- **判定の時刻は一切変えない。見える位置だけが変わる**
local T3DHs = {}

-- TimingGroup（拡張ファイルの timinggroup 行）。ノーツグループごとの自前のソフラン。
-- 行のあるグループはエンジンの p を使わず、ここで作る「位置」から奥行きを出す
-- （エンジンの p と同じ式: 残り = (Pos(ノーツ時刻) - Pos(今)) / 窓）。譜面の scroll からは独立する。
--   raw    … 読込中の行。グループ -> { {t, kind, v, e, ease, order, src} }
--   groups … グループ -> { ps = 区間の列, mono = 位置が時刻とともに減らないか }
--   cache  … nid -> { tg, segs, [点] = 位置 }（ノーツの点の位置は時刻だけで決まるので一度だけ求める）
--   now    … このフレームの「今」の位置（TimingGroup -> 位置）。nowT が変わったら作り直す
local T3DTg = { raw = {}, groups = {}, cache = {}, now = {}, nowT = nil, order = 0 }

-- 仮想ノーツ（OnProcessNote で Note:AddVirtual したもの）。小節線・空中要素の時刻に置く目印で、
-- エンジンがくれる p から「譜面の scroll 込みの位置」を読む（床のノーツと同じ動きになる）。
--   type が base 以上のものが目印。判定には混ぜない（T3DFindNotes）。
--   エンジンは nid を振り直し、独自のフィールドを捨てるので、時刻（ms に丸めた値）で引く。
--   byT   … 丸めた時刻 -> { t, rem = 1 - p, at = rem を読んだ時刻 }
--   rate  … rem が 1ms あたりに減る量（= 今の scroll / 窓）。Update が OnNoteMove より先に来ても
--           rem を今の時刻まで進めて使うため
--   measure … 小節線の時刻（昇順）。ok = false なら仮想ノーツを使わず、時刻から位置を出す（従来の方式）
local T3DVirt = { base = 90, count = 0, bufs = {}, byT = {}, rate = 0, ok = false, measure = {} }
-- 「まだ出ていない（奥）」を表す奥行き。T3DUpdateMeasure より前で宣言しておく（後ろだと nil になる）
local T3DFarZ = 1e9

-- ノーツ速度の補正。**大きいほど速い**（見えている時間が 1/T3DSpeed になる）。
-- ゲーム本体のノーツスピード設定はそのまま効く。これはその上に掛ける倍率。
--
-- なぜ要るか: 遠近のあるレーンでは、奥にいる間はノーツが画面上ほとんど動かない。
-- 奥行き4000のうち手前1000（25%）で画面移動の6割を稼ぐので、本体の設定だけだと
-- 「長く止まってから最後だけ急に来る」動きになり、標準スキンよりかなり遅く見える。
-- 実機では本体の設定を1->10まで上げてようやく標準スキンの1くらいだった（2026-09-20）ので、
-- その差をそのまま倍率にしてある。速すぎ／遅すぎたらこの数字だけ変える
-- （起動時のログに実測の窓と、結果として何ms見えているかを出している）
local T3DSpeed = 5

--------------------------------------------------------------------------------
-- 判定とスコア
--------------------------------------------------------------------------------
-- 入力遅延の補正はゲーム本体の設定（オフセット）が受け持つ。スキン側では何も足さない。
-- 判定が全体に早い／遅いと感じたら本体のオフセット設定で合わせる

-- 実際に使う判定幅(ms)。Init で JudgeBase から作り直す
local JudgeWindow = { Best = 40, Cool = 80, Good = 120, Miss = 150 }
-- 判定レベル Normal（ゲーム内の表示は C）のときの基準値
local JudgeBase   = { Best = 40, Cool = 80, Good = 120, Miss = 150 }
-- Play:GetJudge() のレベル -> 判定幅の倍率。
-- 本体が各レベルで使っている実際の ms は公開されていないので、
-- 「Easy ほど広く Hard ほど狭い」という関係だけを再現したスキン独自の表。
-- 添字は Easy=1 / Easy+=2 / Normal=3 / Normal+=4 / Hard=5（ゲーム内の表示は A〜E）。Pro(11〜15) はさらに狭める
-- 2026-10-16: C 以外だと挙動がおかしくなるので、一旦どのレベルでも C（倍率 1）に固定している。
-- この表はログに「本来の倍率」を出すのにだけ使う（T3DApplyJudgeLevel）
local JudgeScale     = { 1.35, 1.2, 1.0, 0.85, 0.7 }
local JudgeProScale  = 0.85
local JudgeLevelName = { 'A(Easy)', 'B(Easy+)', 'C(Normal)', 'D(Normal+)', 'E(Hard)' }

local JudgeType   = { Best = 1, Cool = 2, Good = 3, Miss = 4 }
local JudgeWeight = { 1.0, 0.6, 0.3, 0.0 }   -- Best/Cool/Good/Miss のスコア係数

-- HP（体力ゲージ）。HUD の Score-HP-Fill を動かすためのもので、
-- 0 になっても失敗にはしない（最後まで遊べる）
local HPStart = 100
local HPDelta = { 0.4, 0.2, -2.0, -6.0 }   -- Best / Cool / Good / Miss での増減
-- ゲージの下限。本体が HP=0 を失敗扱いにするようなら 1 にすると最後まで遊べる
local HPFloor = 0
local T3DHP   = HPStart

local T3DScore = {
  total     = 1000000,
  perNote   = 0,
  current   = 0,
  combo     = 0,
  maxCombo  = 0,
  noteCount = 0,
  judged    = 0,
  counts    = { 0, 0, 0, 0 },   -- Best, Cool, Good, Miss
  -- コンボが一度でも切れたか。フルコンボの判定に使う。
  -- Wipe の取り逃しはコンボを切らないので、Miss の数では見られない
  broken    = false,
}

-- 押下中・切れた状態の Hold/Slide。nid -> { info, pending, auto, lostAt, broken, judged }
local T3DHolds = {}
-- 判定が済んだ床ノーツ。nid -> true。
-- SetNoteFinish がエンジン側の一覧に反映される時機に頼らず、同じフレームに別の指が
-- 同じノーツを取っても二重に数えないようにする
local T3DJudged = {}

--- 1ステップ実行してログに残す。失敗しても後続を止めない
--- Alpha は整数(0〜100)しか受け付けない。小数を渡すとエラーも出ずに 0 扱いになって消えるので、
--- 計算で求めた不透明度は必ずこれを通す
function T3DAlpha(v)
  v = math.floor(v + 0.5)
  if v < 0 then return 0 end
  if v > 100 then return 100 end
  return v
end

--- 変わったときだけ書く Alpha / Order。
--- プロパティへの代入は1回ごとに C# 側を呼ぶので、同じ値の書き直しがフレームレートに直接効く。
--- 最後に書いた値を Lua 側で覚えておき、違うときだけ書く。
--- **このキャッシュを使う Grid は Alpha / Order を必ずここ経由で書くこと**（直接書くと覚えている値とずれる）
local T3DQState = setmetatable({}, { __mode = 'k' })

function T3DSetA(q, a)
  local s = T3DQState[q]
  if s == nil then
    s = {}
    T3DQState[q] = s
  end
  if s.a ~= a then
    q.Alpha = a
    s.a = a
  end
end

--- 変わったときだけ塗る色。key は色の種類を表す値（ここでは「切れているか」の true/false）
function T3DSetTint(q, key, r, g, b)
  local s = T3DQState[q]
  if s == nil then
    s = {}
    T3DQState[q] = s
  end
  if s.c ~= key then
    q:SetColor(r, g, b)
    s.c = key
  end
end

function T3DSetOrder(q, o)
  local s = T3DQState[q]
  if s == nil then
    s = {}
    T3DQState[q] = s
  end
  if s.o ~= o then
    q.Order = o
    s.o = o
  end
end

--- 毎フレームの処理や入力処理を守る。エラーは握り潰さず、最初の数件だけログに出す
local T3DErrLogged = 0
--- 引数は fn にそのまま渡す。毎フレームの処理は T3DSafe('X', T3DUpdateX, t) の形で呼び、
--- function() ... end を毎回作らない（クロージャもフレームごとのゴミになる）
function T3DSafe(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok and T3DErrLogged < 30 then
    T3DErrLogged = T3DErrLogged + 1
    print('[T3D] エラー(' .. label .. '): ' .. tostring(err))
  end
  return ok
end

--------------------------------------------------------------------------------
-- 計測（T3D.PerfLog = true のときだけ）
--   5秒ごとに [T3D] perf: ... を出す。
--   frame   : フレーム間隔。wall は os.clock（使えれば）、song は Game:Time() の差分
--   update  : Update 1回の処理時間 / noteMove : 1フレームぶんの OnNoteMove の合計時間
--   notes   : 1フレームあたりの OnNoteMove の呼び出し回数（エンジンが動かしているノーツ数）
--   kids    : ノーツの子のキャッシュを作り直した回数。notes x フレーム数に近ければキャッシュが効いていない
--------------------------------------------------------------------------------
local T3DClock = nil      -- os.clock が使えればその関数
local T3DPerf = nil

function T3DPerfInit()
  local ok, v = pcall(function() return os.clock() end)
  if ok and type(v) == 'number' then T3DClock = os.clock end
  T3DPerf = {
    since = nil, frames = 0,
    lastWall = nil, lastSong = nil,
    wallSum = 0, wallMax = 0, songSum = 0, songMax = 0, slow = 0,
    updSum = 0, updMax = 0,
    moveSum = 0, moveMax = 0, moveFrame = 0,
    noteCalls = 0, noteMax = 0, noteFrame = 0,
    kidBuilds = 0,
  }
  print('[T3D]   計測: os.clock ' .. (T3DClock and '使える' or '使えない（Game:Time の差分だけ出す）'))
end

--- Update の先頭で呼ぶ。前のフレームぶんを締めて集計する
function T3DPerfFrame(t)
  local p = T3DPerf
  local wall = T3DClock and T3DClock() or nil
  if p.lastSong ~= nil then
    local ds = t - p.lastSong
    p.frames = p.frames + 1
    p.songSum = p.songSum + ds
    if ds > p.songMax then p.songMax = ds end
    if wall ~= nil and p.lastWall ~= nil then
      local dw = (wall - p.lastWall) * 1000
      p.wallSum = p.wallSum + dw
      if dw > p.wallMax then p.wallMax = dw end
      if dw > 20 then p.slow = p.slow + 1 end
    end
    if p.moveFrame > p.moveMax then p.moveMax = p.moveFrame end
    p.moveSum = p.moveSum + p.moveFrame
    if p.noteFrame > p.noteMax then p.noteMax = p.noteFrame end
    p.noteCalls = p.noteCalls + p.noteFrame
  end
  p.moveFrame, p.noteFrame = 0, 0
  p.lastSong, p.lastWall = t, wall
  if p.since == nil then p.since = t end

  if t - p.since >= 5000 and p.frames > 0 then
    local n = p.frames
    print(string.format(
      '[T3D] perf: t=%.0f frames=%d | frame wall avg=%.1f max=%.1f (>20ms:%d) song avg=%.1f max=%.1f'
      .. ' | update avg=%.2f max=%.2f | noteMove avg=%.2f max=%.2f | notes avg=%.1f max=%d | kids=%d | mem=%.0fKB',
      t, n, p.wallSum / n, p.wallMax, p.slow, p.songSum / n, p.songMax,
      p.updSum / n, p.updMax, p.moveSum / n, p.moveMax,
      p.noteCalls / n, p.noteMax, p.kidBuilds, collectgarbage('count')))
    p.since, p.frames = t, 0
    p.wallSum, p.wallMax, p.songSum, p.songMax, p.slow = 0, 0, 0, 0, 0
    p.updSum, p.updMax, p.moveSum, p.moveMax = 0, 0, 0, 0
    p.noteCalls, p.noteMax, p.kidBuilds = 0, 0, 0
  end
end

local function Step(label, fn)
  local ok, err = pcall(fn)
  if ok then
    print('[T3D] step: ' .. label .. ' OK')
  else
    print('[T3D] step: ' .. label .. ' FAILED -> ' .. tostring(err))
  end
  return ok
end

--------------------------------------------------------------------------------
-- 画面の変形（本体は「画面演出」の節）。投影の最後に掛けるので投影より前に置く
--
-- ノーツはエンジンのコンテナにいてグループに入っていないので、グループの X / Rotate / Scale を
-- 動かすとノーツだけ取り残される（TestCode31 で確認）。揺れ・波打ち・グリッチは頂点をずらして作る。
-- 波打ちとグリッチは判定線に近いほど弱め、判定線の上では 0 にする（判定とタッチ位置を動かさない）。
-- 揺れは画面全体を平行移動するだけなので、タッチ側で同じ量を差し引く
--------------------------------------------------------------------------------
local T3DWarp = {
  on     = false,   -- 変形を掛けるか。演出が止まっていれば false で、投影は今までどおり
  dirty  = false,   -- 床の静的な部分を描き直すか（変形が動いている間と、止まった直後の1回）
  shakeX = 0, shakeY = 0,
  waveAmp = 0, wavePhase = 0, waveK = 0,
  glitch = {}, glitchN = 0,   -- 横にずらす帯 { y0, y1, dx }。有効なのは先頭 glitchN 個
}
-- 設定で消されている演出（T3DLoadSettings が読む）。画面演出の節から読むのでここで宣言する
local T3DHide = {}
-- 画面演出の定数。メインチャンクの local は 200 個までなので、演出の定数はこの表にまとめる
local FxConf = {
  WarpFadeZ = 300,       -- 判定線からこの奥行きまでで変形を 0 -> 1 に強める（600 では下側が弱すぎた）
  WaveLen   = 140,       -- 波打ちの波長（画面上）。fx 行で変えられる
  WaveSpeed = 0.006,     -- 波打ちの流れる速さ（rad/ms）
  GlitchStepMs = 45,     -- グリッチの帯を作り直す間隔
  GlitchBandN  = 8,      -- 横にずらす帯の最大数
  GlitchBarN   = 8,      -- ノイズの線
  GlitchBlockN = 12,     -- ブロックノイズ（小さな矩形）
  -- グリッチの線とブロックの色: 白 / シアン / マゼンタ / 黒
  GlitchColors = { { 255, 255, 255 }, { 60, 255, 255 }, { 255, 60, 255 }, { 0, 0, 0 } },
  ShakeStepMs = 25,      -- 揺れの向きを変える間隔
  ShakeMax    = 40,      -- shake 100 のときの揺れ幅（画面上）
  NoiseStepMs = 50,      -- フィルムノイズを動かす間隔
  -- 常時自動の演出
  MissEdgeAlpha  = 35,   -- Miss したときの赤い縁の濃さ（55 は濃すぎた）
  MissEdgeMs     = 450,  -- 赤い縁が消えるまで
  ComboPulseStep = 100,  -- このコンボ数ごとにコンボ表示を膨らませる
  ComboPulseMs   = 250,
  ComboPulseFrom = 1.3,
  -- RGB ずれ: 明るい部品ごとに赤とシアンの複製を左右へずらして置く
  RgbAlpha    = 55,      -- 複製の濃さ（元の不透明度に掛ける %）
  -- 1フレームに置ける複製の数（赤・シアンそれぞれ）。素材ごとに置き場を分ける
  RgbPool = { tap = 60, wipe = 40, long = 150, bar = 16, judge = 4, white = 80, beat = 12 },
  -- 置き去り型の残像
  StampPool   = 64,      -- 残像の数（Tap / Wipe ごと）
  StampStepMs = 40,      -- 残像を置く間隔
  StampLifeMs = 180,     -- 残像が消えるまで
  CopyColor   = { 140, 220, 255 },   -- 残像の既定の色
  -- モノクロ
  MonoBgAlpha = 55,      -- mono 100 のとき背景に被せる暗い灰色の濃さ
  MonoTex = { [TexTap] = 'mono-note-tap.png', [TexWipe] = 'mono-note-wipe.png' },
}

--- 投影した点に画面の変形を掛ける。z はワールドの奥行き（判定線が 0）
function T3DApplyWarp(px, py, z)
  local wp = T3DWarp
  local w = z / FxConf.WarpFadeZ
  if w > 1 then w = 1 end
  if w > 0 then
    if wp.waveAmp ~= 0 then
      px = px + wp.waveAmp * w * math.sin(py * wp.waveK + wp.wavePhase)
    end
    for i = 1, wp.glitchN do
      local g = wp.glitch[i]
      if py >= g.y0 and py < g.y1 then
        px = px + g.dx * w
        break
      end
    end
  end
  return px + wp.shakeX, py + wp.shakeY
end

--------------------------------------------------------------------------------
-- 投影 / 逆射影
--------------------------------------------------------------------------------

--- ワールド(x=横, y=高さ[床は0], z=奥行き[判定線が0, 奥が+]) -> グループ内座標
--- @return number sx, number sy, number scale, number depth
-- Pitch / Roll の cos・sin。T3DProject は1フレームに数百回呼ばれるので、角度が変わったときだけ求め直す。
-- Cam を直接書き換えるコード（T3DApplyTrackAngle が Roll を一時的に 0 にする等）があっても、
-- 値そのものを比べているので取り違えない
local T3DPjPitch, T3DPjCosP, T3DPjSinP = nil, 1, 0
local T3DPjRoll, T3DPjCosR, T3DPjSinR = nil, 1, 0

function T3DProject(x, y, z)
  if Cam.Pitch ~= T3DPjPitch then
    T3DPjPitch = Cam.Pitch
    local p = math.rad(T3DPjPitch)
    T3DPjCosP, T3DPjSinP = math.cos(p), math.sin(p)
  end
  local cosP, sinP = T3DPjCosP, T3DPjSinP
  local dx = x - Cam.X
  local dy, dz = y - Cam.Y, z + Cam.Z
  local cy =  dy * cosP + dz * sinP
  local cz = -dy * sinP + dz * cosP
  if cz < 1 then return nil end
  local s = Cam.Focal / cz
  local px, py = dx * s, cy * s + Cam.ShiftY
  if Cam.Roll ~= 0 then
    -- 空中レーンの中心 (0, T3DRollPivotY) まわりに回す
    if Cam.Roll ~= T3DPjRoll then
      T3DPjRoll = Cam.Roll
      local r = math.rad(T3DPjRoll)
      T3DPjCosR, T3DPjSinR = math.cos(r), math.sin(r)
    end
    local cr, sr = T3DPjCosR, T3DPjSinR
    local ox, oy = px - T3DRollPivotX, py - T3DRollPivotY
    px = T3DRollPivotX + ox * cr - oy * sr
    py = T3DRollPivotY + ox * sr + oy * cr
  end
  if T3DWarp.on then px, py = T3DApplyWarp(px, py, z) end
  return px, py, s, cz
end

--- グループ内座標 -> 床平面(y=0)上のワールド座標（逆射影）
--- @return number x, number z, number scale
function T3DUnproject(sx, sy)
  local px, py = sx, sy
  if Cam.Roll ~= 0 then                         -- ロールを先に打ち消す（基準点は投影と同じ）
    local r = -math.rad(Cam.Roll)
    local cr, sr = math.cos(r), math.sin(r)
    local ox, oy = px - T3DRollPivotX, py - T3DRollPivotY
    px = T3DRollPivotX + ox * cr - oy * sr
    py = T3DRollPivotY + ox * sr + oy * cr
  end
  py = py - Cam.ShiftY
  local p = math.rad(Cam.Pitch)
  local cosP, sinP = math.cos(p), math.sin(p)
  local k = py / Cam.Focal
  local den = sinP - k * cosP
  if den <= 0.0001 then return nil end          -- 地平線より上は床に当たらない
  local d = Cam.Y * (k * sinP + cosP) / den     -- d = z + Cam.Z
  local cz = Cam.Y * sinP + d * cosP
  if cz < 1 then return nil end
  local s = Cam.Focal / cz
  return px / s + Cam.X, d - Cam.Z, s
end

--- トラック角度からカメラを組む。判定線の位置と幅は変えずに傾きだけ変える。
--- zoom を渡すと判定線の画面位置はそのままでトラックの見かけの幅だけが変わる
--- （Focal を直接いじると判定線ごと動いてしまうので、判定線上のスケールを倍率にする）
--- pivotY を渡すと Roll の回転軸をその画面Yに固定する（譜面の rollpivot 用）。
--- nil なら定数 RollPivot の指定に従う
function T3DApplyTrackAngle(angle, zoom, pivotY)
  -- 下で T3DProject を使って回転軸や空中判定線の位置を測る。画面の変形が入ると
  -- 揺れや波がそのまま軸に混ざるので、測っている間は外す
  local warpOn = T3DWarp.on
  T3DWarp.on = false
  local zm = zoom or 1
  T3DZoomNow = zm
  local scale = JudgeLineScale * zm
  local pitch = 90 - angle
  local p = math.rad(pitch)
  local sinP, cosP = math.sin(p), math.cos(p)
  -- 判定線中心 (0, 0, 0) のカメラ空間座標
  local cz0 = Cam.Y * sinP + Cam.Z * cosP
  local cy0 = -Cam.Y * cosP + Cam.Z * sinP

  -- 先に全部計算してからまとめて入れる。途中で落ちると
  -- 「傾きだけ変わって焦点距離は前のまま」という噛み合わない状態になるため
  local focal  = scale * cz0
  local shiftY = JudgeScreenY - cy0 * scale
  Cam.Pitch  = pitch
  Cam.Focal  = focal
  Cam.ShiftY = shiftY

  -- 床の手前端: 画面下端に投影される床上の奥行きを逆射影で求める。
  -- Roll が入っていると画面中央の列が回ってしまい手前端が揺れるので、傾きは外して測る
  local roll = Cam.Roll
  Cam.Roll = 0
  local _, nearZ = T3DUnproject(0, FloorBottomY)
  Cam.Roll = roll
  if nearZ ~= nil and nearZ < 0 and nearZ > -Cam.Z + 60 then
    T3DFloorNear = nearZ
  end

  -- 空中判定線の高さ: 判定線(z=0)の真上で、画面上 SkyLineConf.ScreenOffset だけ上に来る高さを解く。
  --   カメラ空間で d = 高さ - Cam.Y とおくと
  --   (d*cos + Z*sin) / (-d*sin + Z*cos) = k  を d について解いた式
  -- 画面上の間隔にも zoom を掛ける。そうしないとズームしたとき空中判定線だけ動かず、
  -- 空中要素が床に押し潰されて見える（掛けると高さは zoom によらず一定になる）
  local k = (JudgeScreenY + SkyLineConf.ScreenOffset * zm - Cam.ShiftY) / Cam.Focal
  local den = cosP + k * sinP
  if den > 0.0001 then
    local h = Cam.Y + Cam.Z * (k * cosP - sinP) / den
    if h > 10 then T3DHeightMax = h end
  end

  -- Roll の回転軸。ロールを外して投影すれば、そのときの画面位置がそのまま軸になる。
  -- パンやズームで動くので毎回求め直す
  local roll = Cam.Roll
  Cam.Roll = 0

  -- 横はレーンの中心（パンに追従）。縦は RollPivot の指定どおり
  local cx, judgeY = T3DProject(0, 0, 0)
  if cx ~= nil then T3DRollPivotX = cx end

  local py = pivotY
  if py ~= nil then
    -- 譜面の rollpivot が効いている。RollPivot の指定は見ない
  elseif type(RollPivot) == 'number' then
    py = RollPivot
  elseif RollPivot == 'center' then
    py = 0
  elseif RollPivot == 'judge' then
    py = judgeY
  elseif RollPivot == 'sky' then
    local _, sy = T3DProject(0, T3DHeightMax, 0)
    py = sy
  else
    -- 'lane': 床の手前端と奥の端の真ん中。ここを軸にすると 180度でその場で裏返る
    local _, nearY = T3DProject(0, 0, T3DFloorNear)
    local _, farY  = T3DProject(0, 0, T3DDepth)
    if nearY ~= nil and farY ~= nil then py = (nearY + farY) * 0.5 end
  end
  if py ~= nil then T3DRollPivotY = py end

  Cam.Roll = roll
  T3DWarp.on = warpOn
end

--------------------------------------------------------------------------------
-- 譜面からのカメラ演出（拡張ファイルの cam 行）
--
-- 全要素が T3DProject / T3DUnproject を通るので、Cam を書き換えるだけで
-- 床・ノーツ・帯・空中要素・演出が一斉に追従する。逆射影も同じ Cam を読むので、
-- カメラを振っている最中でも「見えている位置」と「触って取れる位置」がずれない。
--------------------------------------------------------------------------------

--- cam 行を1つ積む。範囲外の値は端で丸めて警告する
function T3DAddCam(ch, s, e, v1, v2, ease, src)
  local lo, hi = CamRange[ch][1], CamRange[ch][2]
  local function clamp(v)
    if v < lo then
      T3DCamReport('警告', src, string.format('%s の値 %.3f は範囲外なので %.3f にした', ch, v, lo))
      return lo
    elseif v > hi then
      T3DCamReport('警告', src, string.format('%s の値 %.3f は範囲外なので %.3f にした', ch, v, hi))
      return hi
    end
    return v
  end
  if T3DCamEvents[ch] == nil then T3DCamEvents[ch] = {} end
  table.insert(T3DCamEvents[ch], {
    s = s, e = e, v1 = clamp(v1), v2 = clamp(v2), ease = ease or 0, src = src,
  })
end

--- 積んだ cam 行を項目ごとに時刻順へ並べ、重なりを警告する
function T3DCommitCam()
  local total, used = 0, {}
  for ch, list in pairs(T3DCamEvents) do
    table.sort(list, function(a, b) return a.s < b.s end)
    for i = 2, #list do
      if list[i].s < list[i - 1].e then
        T3DCamReport('警告', list[i].src,
          string.format('%s の区間が直前の区間(%dms〜%dms)と重なっている。後の行が優先される',
            ch, list[i - 1].s, list[i - 1].e))
      end
    end
    T3DCamIndex[ch] = 1
    total = total + #list
    used[#used + 1] = string.format('%s=%d', ch, #list)
  end
  T3DCamOn = total > 0
  if T3DCamOn then
    table.sort(used)
    print(string.format('[T3D] カメラ演出: %d区間 (%s)', total, table.concat(used, ' ')))
  end
end

--- その項目が譜面に1行でも書かれているか
function T3DCamActive(ch)
  local list = T3DCamEvents[ch]
  return list ~= nil and #list > 0
end

--- 時刻 t における項目の値。区間の前は既定値、区間の後は終了値を保つ
function T3DCamValueAt(ch, t)
  local list = T3DCamEvents[ch]
  if list == nil or #list == 0 then return CamBase[ch] end
  local i = T3DCamIndex[ch] or 1
  while i > 1 and t < list[i].s do i = i - 1 end
  while i < #list and t >= list[i + 1].s do i = i + 1 end
  T3DCamIndex[ch] = i
  local ev = list[i]
  if t < ev.s then
    -- 最初の区間より前だけが既定値。2つ目以降の手前は直前の区間の終了値のまま
    if i == 1 then return CamBase[ch] end
    return list[i - 1].v2
  end
  if t >= ev.e then return ev.v2 end
  return ev.v1 + (ev.v2 - ev.v1) * T3DEase((t - ev.s) / (ev.e - ev.s), ev.ease)
end

--- 毎フレーム、cam 行の値を Cam に流し込む。cam 行が無ければ何もしない
function T3DUpdateCam(t)
  if not T3DCamOn then return end
  Cam.X    = T3DWorldX(T3DCamValueAt('x', t))
  Cam.Y    = T3DCamValueAt('y', t)
  Cam.Z    = T3DCamValueAt('z', t)
  Cam.Roll = T3DCamValueAt('roll', t)
  -- 回転軸は譜面に rollpivot が書かれているときだけ上書きする。
  -- 書かれていなければ nil を渡して、スキンの RollPivot 設定（'lane' 等）に任せる
  local pivot = nil
  if T3DCamActive('rollpivot') then pivot = T3DCamValueAt('rollpivot', t) end

  -- 傾きとズームは Focal / ShiftY / 床の手前端 / 空中判定線の高さを作り直すので最後に
  T3DApplyTrackAngle(T3DCamValueAt('angle', t), T3DCamValueAt('zoom', t) * UserZoom, pivot)
end

--------------------------------------------------------------------------------
-- 画面演出（拡張ファイルの fx 行 + 常時自動の演出）
--
-- 重ね板: 全画面の Grid を Order 990〜 に置く。HUD やノーツより手前に来る（TestCode31 で確認）。
--   素材は白地（fx-vignette / fx-scanline）にして SetColor で塗る。fx-noise は白と黒の粒をそのまま使う
-- 画面の変形: 揺れ / 波打ち / グリッチ。T3DWarp に値を入れると T3DProject が全頂点に掛ける
--
-- fx 行の書式（ease は cam と同じ 0〜3、色は #rrggbb）
--   値を保つもの（区間の前は 0、区間の後は終了値のまま。cam 行と同じ）
--     fx,開始ms,終了ms,fade,開始,終了[,ease[,色]]   … 色を被せる。既定は黒（暗転）。0〜100
--     fx,開始ms,終了ms,vignette,開始,終了[,ease]   … 画面の縁を暗く。0〜100
--     fx,開始ms,終了ms,scanline,開始,終了[,ease]   … 走査線。0〜100
--     fx,開始ms,終了ms,noise,開始,終了[,ease]      … フィルムノイズ。0〜100
--     fx,開始ms,終了ms,letterbox,開始,終了[,ease]  … 上下の黒帯。画面の高さに対する %（0〜40）
--     fx,開始ms,終了ms,wave,開始,終了[,ease[,波長]] … 波打ち。振れ幅（0〜200）、波長は画面上 40〜1000（既定 140）
--     fx,開始ms,終了ms,rgb,開始,終了[,ease]        … RGB ずれ（ノーツ・レーンのバー・判定線・帯・小節線・空中要素の
--                                                   左右に赤とシアン）。ずれ幅 0〜40（画面上）
--     fx,開始ms,終了ms,afterimage,開始,終了[,ease[,色]] … 置き去り型の残像。濃さ 0〜100
--     fx,開始ms,終了ms,mono,開始,終了[,ease]       … モノクロ寄り。0〜100。ノーツは 50 以上の間に
--                                                   奥に現れたものが灰色になる（素材を差し替えるため途中では変わらない）
--   区間の中だけ効くもの
--     fx,開始ms,終了ms,flash,強さ[,色]             … 強さから 0 へ薄れる。既定は白。0〜100
--     fx,開始ms,終了ms,shake,強さ                  … 揺れ。強さから 0 へ弱まる。0〜100
--     fx,開始ms,終了ms,glitch,強さ                 … 横方向のずれ・ノイズの線・ブロックノイズ。区間の間ずっと。0〜300
--------------------------------------------------------------------------------
local Fx = {
  kinds = {
    fade      = { hold = true, hi = 100 },
    vignette  = { hold = true, hi = 100 },
    scanline  = { hold = true, hi = 100 },
    noise     = { hold = true, hi = 100 },
    letterbox = { hold = true, hi = 40 },
    wave      = { hold = true, hi = 200 },
    flash     = { hold = false, hi = 100, decay = true },
    shake     = { hold = false, hi = 100, decay = true },
    glitch    = { hold = false, hi = 300, decay = false },
    rgb        = { hold = true, hi = 40 },    -- 100 まで開けると別のレーンが3本並んで見えた
    afterimage = { hold = true, hi = 100 },
    mono       = { hold = true, hi = 100 },
  },
  events  = {},         -- 種類 -> 区間の並び（開始の早い順）
  index   = {},         -- 種類 -> 今見ている区間の添字
  chartOn = false,      -- fx 行が1行でもあるか
  boards  = {},         -- 重ね板。名前 -> Grid
  glitchBars = {},
  glitchBlocks = {},
  glitchAt = -1,        -- グリッチの帯を最後に作り直した時刻
  shakeAt = -1,
  noiseAt = -1,
  letterbox = -1,       -- 黒帯の頂点を最後に書いたときの高さ
  missAt = nil,         -- 最後に Miss した時刻（赤い縁）
  combo = nil,          -- HUD のコンボ表示（Score-Combp）
  comboShown = 0,       -- 拡大を最後に出したコンボ数
  -- 複製
  pools = {},           -- RGB ずれの置き場（毎フレーム使い回す）。'tapR' などの名前 -> { q, n, used, prev }
  stamps = {},          -- 置き去り型の残像。'tap' / 'wipe' -> { q, born, a0, next, n }
  stampAt = {},         -- nid -> 最後に残像を置いた時刻
  now = 0,              -- 今フレームの時刻（OnNoteMove から Game:Time() を呼ばないため）
  rgbPx = 0, afterA = 0, afterEv = nil,
  -- T3DSetQuad / T3DSetBand / T3DSetBand3 / T3DSetHBar が最後に書いた4頂点（x0,y0 .. x3,y3）。
  -- RGB ずれと残像は、元の部品を描いた直後にこれを写す（投影し直さない）
  lastV = {},
  -- モノクロ
  monoV = 0,            -- 今の mono の値（0〜100）
  monoStep = 0,         -- 色を塗り直した段階（0〜1 を 0.1 刻み）
  monoBars = {}, monoJudge = nil, monoSky = nil,
  airFill = { 150, 115, 255 }, airEdge = { 202, 185, 255 },   -- AirSlide の色（T3DAirSlideColor と同じ）
}

--- 画面座標の矩形を Grid に書く（原点が画面中央、上が +）
function T3DSetRect(q, l, r, b, top)
  q:SetVertex(0, l, b)
  q:SetVertex(1, r, b)
  q:SetVertex(2, l, top)
  q:SetVertex(3, r, top)
end

--- '#rrggbb' -> r, g, b。読めなければ nil
function T3DParseColor(s)
  if type(s) ~= 'string' then return nil end
  local r, g, b = string.match(s, '^#(%x%x)(%x%x)(%x%x)$')
  if r == nil then return nil end
  return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

function T3DFxReport(level, src, msg) T3DExReport('演出', level, src, msg) end

--- fx 行を1つ読む。f は T3DParseAir が区切った値
function T3DParseFx(f, src)
  local kind = f[4]
  local def = Fx.kinds[kind]
  local function num(i) return type(f[i]) == 'number' end
  if not (num(2) and num(3) and def ~= nil) then
    T3DFxReport('却下', src, '書式は fx,開始ms,終了ms,種類,値...（種類は fade/vignette/scanline/noise/'
      .. 'letterbox/wave/flash/shake/glitch）')
    return
  end
  if f[3] < f[2] then
    T3DFxReport('却下', src, '終了が開始より前')
    return
  end
  local function clamp(v)
    if v < 0 or v > def.hi then
      local c = v < 0 and 0 or def.hi
      T3DFxReport('警告', src, string.format('%s の値 %.1f は範囲外なので %.1f にした', kind, v, c))
      return c
    end
    return v
  end

  local ev = { s = f[2], e = f[3], src = src }
  local colorAt
  if def.hold then
    if not (num(5) and num(6)) then
      T3DFxReport('却下', src, string.format('書式は fx,開始ms,終了ms,%s,開始,終了[,ease]', kind))
      return
    end
    ev.v1, ev.v2 = clamp(f[5]), clamp(f[6])
    ev.ease = num(7) and f[7] or 0
    if kind == 'wave' then
      -- wave だけは 8番目が色ではなく波長
      if f[8] ~= nil then
        if num(8) and f[8] >= 40 and f[8] <= 1000 then
          ev.len = f[8]
        else
          T3DFxReport('警告', src, '波長は 40〜1000。既定の ' .. FxConf.WaveLen .. ' にした')
        end
      end
    else
      colorAt = 8
    end
  else
    if not num(5) then
      T3DFxReport('却下', src, string.format('書式は fx,開始ms,終了ms,%s,強さ', kind))
      return
    end
    ev.v1 = clamp(f[5])
    colorAt = 6
  end
  if colorAt ~= nil and f[colorAt] ~= nil then
    local r, g, b = T3DParseColor(f[colorAt])
    if r == nil then
      T3DFxReport('警告', src, '色は #rrggbb で書く。既定の色にした')
    else
      ev.r, ev.g, ev.b = r, g, b
    end
  end
  if Fx.events[kind] == nil then Fx.events[kind] = {} end
  table.insert(Fx.events[kind], ev)
end

--- fx 行を種類ごとに時刻順へ並べる
function T3DCommitFx()
  local total, used = 0, {}
  for kind, list in pairs(Fx.events) do
    table.sort(list, function(a, b) return a.s < b.s end)
    Fx.index[kind] = 1
    total = total + #list
    used[#used + 1] = string.format('%s=%d', kind, #list)
  end
  Fx.chartOn = total > 0
  if Fx.chartOn then
    table.sort(used)
    print(string.format('[T3D] 画面演出: %d区間 (%s)', total, table.concat(used, ' ')))
  end
end

--- 値を保つ種類の、時刻 t の値と、その値を決めている区間（色を読むため）
function T3DFxHoldAt(kind, t)
  local list = Fx.events[kind]
  if list == nil then return 0, nil end
  local i = Fx.index[kind] or 1
  while i > 1 and t < list[i].s do i = i - 1 end
  while i < #list and t >= list[i + 1].s do i = i + 1 end
  Fx.index[kind] = i
  local ev = list[i]
  if t < ev.s then
    if i == 1 then return 0, nil end
    return list[i - 1].v2, list[i - 1]
  end
  if t >= ev.e then return ev.v2, ev end
  return ev.v1 + (ev.v2 - ev.v1) * T3DEase((t - ev.s) / (ev.e - ev.s), ev.ease), ev
end

--- 区間の中だけ効く種類の、時刻 t の値（重なっていれば強い方）と、その区間
function T3DFxPulseAt(kind, t)
  local list = Fx.events[kind]
  if list == nil then return 0, nil end
  local i = Fx.index[kind] or 1
  -- 開始順に並んでいるので、終わった区間は飛ばし、リトライで戻ったら巻き戻す
  while i > 1 and list[i - 1].e >= t do i = i - 1 end
  while i <= #list and list[i].e < t do i = i + 1 end
  Fx.index[kind] = i
  local best, bestEv = 0, nil
  local decay = Fx.kinds[kind].decay
  local j = i
  while j <= #list and list[j].s <= t do
    local ev = list[j]
    if t <= ev.e then
      local v = ev.v1
      if decay and ev.e > ev.s then v = v * (1 - (t - ev.s) / (ev.e - ev.s)) end
      if v > best then best, bestEv = v, ev end
    end
    j = j + 1
  end
  return best, bestEv
end

--- 重ね板と複製の置き場を作る。T3DCommitFx の後に呼ぶ。
--- 見えない Grid も毎フレームの描画に効く（fx 行の無い譜面で FPS が約2割落ちた。2026-09-26 実測）ので、
--- 譜面の fx 行に無い種類は作らない。常に作るのは常時自動の Miss の赤い縁だけ
function T3DBuildFx()
  local hw, hh = GameWidth * 0.5, GameHeight * 0.5
  local used = Fx.events
  local function board(name, tex, order, r, g, b)
    local q = T3DGroup:AddGrid('t3d-fx-' .. name, tex)
    if r ~= nil then q:SetColor(r, g, b) end
    T3DSetRect(q, -hw, hw, -hh, hh)
    T3DSetOrder(q, order)
    T3DSetA(q, 0)
    Fx.boards[name] = q
    return q
  end
  local function grid(name, tex, order)
    local q = T3DGroup:AddGrid('t3d-fx-' .. name, tex)
    T3DSetOrder(q, order)
    T3DSetA(q, 0)
    return q
  end

  -- 重ね板。下から: 色の被せ < 走査線 < ノイズ < グリッチの線 < ビネット < Miss の赤い縁 < 黒帯 < フラッシュ
  if used.fade then board('fade', T3DTex, 990, 0, 0, 0) end
  if used.scanline then board('scanline', 'fx-scanline.png', 991, 0, 0, 0) end
  if used.noise then board('noise', 'fx-noise.png', 992) end
  if used.glitch then
    for i = 1, FxConf.GlitchBarN do Fx.glitchBars[i] = grid('glitchbar-' .. i, T3DTex, 993) end
    for i = 1, FxConf.GlitchBlockN do Fx.glitchBlocks[i] = grid('glitchblock-' .. i, T3DTex, 993) end
  end
  if used.vignette then board('vignette', 'fx-vignette.png', 994, 0, 0, 0) end
  board('miss', 'fx-vignette.png', 995, 255, 30, 30)
  if used.letterbox then
    board('barTop', T3DTex, 996, 0, 0, 0)
    board('barBottom', T3DTex, 996, 0, 0, 0)
  end
  if used.flash then board('flash', T3DTex, 997) end
  for i = 1, FxConf.GlitchBandN do T3DWarp.glitch[i] = { y0 = 0, y1 = 0, dx = 0 } end

  -- RGB ずれの置き場。元の部品と同じ形の白い素材を、赤とシアンに塗って使う（毎フレーム使い回す）
  if used.rgb then
    local rgbTex = {
      tap = 'fx-sil-tap.png', wipe = 'fx-sil-wipe.png', long = TexLong,
      bar = 'fx-sil-track-bar.png', judge = 'fx-sil-track-judge.png', white = T3DTex, beat = MeasureConf.Tex,
    }
    for key, tex in pairs(rgbTex) do
      for _, c in ipairs({ { 'R', 255, 40, 40 }, { 'C', 40, 255, 255 } }) do
        local name = key .. c[1]
        local n = FxConf.RgbPool[key]
        local pl = { q = {}, n = n, used = 0, prev = 0 }
        for i = 1, n do
          local q = T3DGroup:AddGrid('t3d-fx-rgb-' .. name .. '-' .. i, tex)
          q:SetColor(c[2], c[3], c[4])
          T3DSetA(q, 0)
          pl.q[i] = q
        end
        Fx.pools[name] = pl
      end
    end
  end

  -- 残像の置き場（置いたら消えるまでそのまま）
  if used.afterimage then
    for _, k in ipairs({ 'tap', 'wipe' }) do
      local st = { q = {}, born = {}, a0 = {}, next = 1, n = FxConf.StampPool }
      for i = 1, st.n do
        local q = T3DGroup:AddGrid('t3d-fx-stamp-' .. k .. '-' .. i, 'fx-sil-' .. k .. '.png')
        T3DSetA(q, 0)
        st.q[i] = q
      end
      Fx.stamps[k] = st
    end
  end

  -- モノクロ: 素材に色の付いた床の部品（左右のバー・判定線・空中判定線・AirTap）に灰色の複製を重ねる。
  -- 床と AirSlide は白地に SetColor なので色を塗り直す。背景は暗い灰色を被せる
  if used.mono then
    for j = 1, #T3DFloorQuads do
      Fx.monoBars[j] = {
        grid('monobar-' .. j .. '-1', 'mono-track-bar.png', 19),
        grid('monobar-' .. j .. '-2', 'mono-track-bar.png', 19),
      }
    end
    Fx.monoJudge = grid('monojudge', 'mono-track-judge.png', 20)
    Fx.monoSky = grid('monosky', 'mono-track-judge.png', 721)
    for n = 1, #T3DAirTapQuads do
      T3DAirTapQuads[n].mono = grid('monoairtap-' .. n, 'mono-note-tap.png', 760)
    end
    board('monoBg', T3DTex, 2, 18, 18, 22)   -- 床(3〜)より下 = 背景の上
  end

  local ok, combo = pcall(function() return Module:Find('Score-Combp') end)
  if ok then Fx.combo = combo end
end

--- 重ね板の不透明度。その種類の fx 行が無くて板を作っていなければ何もしない
function T3DFxBoardA(name, a)
  local q = Fx.boards[name]
  if q ~= nil then T3DSetA(q, a) end
end

--- 色を塗り分ける重ね板。色が変わったときだけ塗る
function T3DFxTint(q, ev, r, g, b)
  if ev ~= nil and ev.r ~= nil then r, g, b = ev.r, ev.g, ev.b end
  T3DSetTint(q, r * 65536 + g * 256 + b, r, g, b)
end

--- グリッチ: 横にずらす帯・ノイズの線・ブロックノイズを作り直す
function T3DGlitchReroll(strength)
  -- math.random は整数しか受け付けないので切り捨てておく
  local hw = math.floor(GameWidth * 0.5)
  local hh = math.floor(GameHeight * 0.5)
  local wp = T3DWarp

  -- 横にずらす帯。細い帯をいくつも（細かい床の1行 約36px と同じくらいの細さ）
  local n = math.random(3, FxConf.GlitchBandN)
  for i = 1, n do
    local g = wp.glitch[i]
    local y0 = math.random(-hh, hh - 6)
    g.y0, g.y1 = y0, y0 + math.random(6, 48)
    g.dx = (math.random() * 2 - 1) * strength
  end
  wp.glitchN = n

  -- ノイズの線（画面の端から端まで）
  local lines = math.random(3, FxConf.GlitchBarN)
  for i = 1, FxConf.GlitchBarN do
    local bar = Fx.glitchBars[i]
    if i <= lines then
      local ly = math.random(-hh, hh - 2)
      T3DSetRect(bar, -hw, hw, ly, ly + math.random(1, 6))
      local c = FxConf.GlitchColors[math.random(1, 3)]
      bar:SetColor(c[1], c[2], c[3])
      T3DSetA(bar, T3DAlpha(15 + 30 * math.random()))
    else
      T3DSetA(bar, 0)
    end
  end

  -- ブロックノイズ（横長の小さな矩形）
  local blocks = math.random(4, FxConf.GlitchBlockN)
  for i = 1, FxConf.GlitchBlockN do
    local q = Fx.glitchBlocks[i]
    if i <= blocks then
      local w = math.random(30, 240)
      local h = math.random(6, 28)
      local x0 = math.random(-hw, hw - w)
      local y0 = math.random(-hh, hh - h)
      T3DSetRect(q, x0, x0 + w, y0, y0 + h)
      local c = FxConf.GlitchColors[math.random(1, 4)]
      q:SetColor(c[1], c[2], c[3])
      T3DSetA(q, T3DAlpha(25 + 35 * math.random()))
    else
      T3DSetA(q, 0)
    end
  end
end

function T3DGlitchOff()
  if T3DWarp.glitchN == 0 then return end
  T3DWarp.glitchN = 0
  for i = 1, FxConf.GlitchBarN do T3DSetA(Fx.glitchBars[i], 0) end
  for i = 1, FxConf.GlitchBlockN do T3DSetA(Fx.glitchBlocks[i], 0) end
end

--- 毎フレーム。描画より先に呼ぶ（画面の変形を全頂点に効かせるため）。
--- chart = 譜面の fx 行を効かせるか（設定 Hide Chart FX で切れる）
function T3DUpdateFx(t)
  local chart = Fx.chartOn and not T3DHide.ChartFx
  local wasOn = T3DWarp.on
  T3DFxUpdateBoards(t, chart)
  T3DFxUpdateWarp(t, chart)
  -- 床の静的な部分は、変形している間と、止めた直後の1回だけ描き直す
  T3DWarp.dirty = T3DWarp.on or wasOn
  T3DFxUpdateCopies(t, chart)
  T3DFxUpdateMiss(t)
end

--- 重ね板（色の被せ・ビネット・走査線・フラッシュ・フィルムノイズ・黒帯）
function T3DFxUpdateBoards(t, chart)
  local B = Fx.boards
  local fade, fadeEv, vig, scan, noise, lbox, flash, flashEv = 0, nil, 0, 0, 0, 0, 0, nil
  if chart then
    fade, fadeEv = T3DFxHoldAt('fade', t)
    vig   = T3DFxHoldAt('vignette', t)
    scan  = T3DFxHoldAt('scanline', t)
    noise = T3DFxHoldAt('noise', t)
    lbox  = T3DFxHoldAt('letterbox', t)
    flash, flashEv = T3DFxPulseAt('flash', t)
  end

  if B.fade ~= nil then
    T3DFxTint(B.fade, fadeEv, 0, 0, 0)
    T3DSetA(B.fade, T3DAlpha(fade))
  end
  T3DFxBoardA('vignette', T3DAlpha(vig))
  T3DFxBoardA('scanline', T3DAlpha(scan))
  if B.flash ~= nil then
    T3DFxTint(B.flash, flashEv, 255, 255, 255)
    T3DSetA(B.flash, T3DAlpha(flash))
  end

  -- フィルムノイズ: 画面より大きい板を少しずつ跳ばして粒を動かす
  T3DFxBoardA('noise', T3DAlpha(noise))
  if noise > 0 and (t - Fx.noiseAt >= FxConf.NoiseStepMs or t < Fx.noiseAt) then
    Fx.noiseAt = t
    local hw, hh = GameWidth * 0.65, GameHeight * 0.65
    local ox = (math.random() * 2 - 1) * GameWidth * 0.15
    local oy = (math.random() * 2 - 1) * GameHeight * 0.15
    if math.random() < 0.5 then
      T3DSetRect(B.noise, ox - hw, ox + hw, oy - hh, oy + hh)
    else
      T3DSetRect(B.noise, ox + hw, ox - hw, oy + hh, oy - hh)   -- 裏返して模様を変える
    end
  end

  -- 黒帯。高さが変わったときだけ頂点を書く
  local barH = math.floor(GameHeight * lbox / 100 + 0.5)
  if barH ~= Fx.letterbox and B.barTop ~= nil then
    Fx.letterbox = barH
    local hw, hh = GameWidth * 0.5, GameHeight * 0.5
    if barH > 0 then
      T3DSetRect(B.barTop, -hw, hw, hh - barH, hh + 10)
      T3DSetRect(B.barBottom, -hw, hw, -hh - 10, -hh + barH)
    end
    T3DSetA(B.barTop, barH > 0 and 100 or 0)
    T3DSetA(B.barBottom, barH > 0 and 100 or 0)
  end
end

--- 画面の変形（波・グリッチ・揺れ）。値は T3DWarp に置き、投影の最後に T3DApplyWarp が掛ける
function T3DFxUpdateWarp(t, chart)
  local wp = T3DWarp
  local wave, shake, glitch = 0, 0, 0
  if chart then
    local waveEv
    wave, waveEv = T3DFxHoldAt('wave', t)
    wp.waveK = 2 * math.pi / ((waveEv ~= nil and waveEv.len) or FxConf.WaveLen)
    shake  = T3DFxPulseAt('shake', t)
    glitch = T3DFxPulseAt('glitch', t)
  end

  wp.waveAmp = wave
  wp.wavePhase = t * FxConf.WaveSpeed
  if glitch > 0 then
    if Fx.glitchAt < 0 or t - Fx.glitchAt >= FxConf.GlitchStepMs or t < Fx.glitchAt then
      Fx.glitchAt = t
      T3DGlitchReroll(glitch)
    end
  else
    Fx.glitchAt = -1
    T3DGlitchOff()
  end
  if shake > 0 then
    if t - Fx.shakeAt >= FxConf.ShakeStepMs or t < Fx.shakeAt then
      Fx.shakeAt = t
      local amp = FxConf.ShakeMax * shake / 100
      wp.shakeX = (math.random() * 2 - 1) * amp
      wp.shakeY = (math.random() * 2 - 1) * amp * 0.6
    end
  else
    wp.shakeX, wp.shakeY = 0, 0
  end
  wp.on = wave > 0 or wp.glitchN > 0 or shake > 0
end

--- 複製（RGB ずれ・残像）とモノクロ。置くのは各部品を描いた直後（T3DRgbCopy / T3DFxHeadCopies）
function T3DFxUpdateCopies(t, chart)
  local rgb, after, afterEv, mono = 0, 0, nil, 0
  if chart then
    rgb = T3DFxHoldAt('rgb', t)
    after, afterEv = T3DFxHoldAt('afterimage', t)
    mono = T3DFxHoldAt('mono', t)
  end
  Fx.now = t
  Fx.rgbPx, Fx.afterA, Fx.afterEv = rgb, after, afterEv
  -- RGB ずれの置き場は毎フレーム使い回すので、左右のバーと判定線も毎フレーム描き直す
  if rgb > 0 then T3DWarp.dirty = true end
  for _, pl in pairs(Fx.pools) do T3DFxPoolFrame(pl) end
  T3DFxUpdateStamps(t)
  -- モノクロの値が動いたら、バーと判定線の灰色の複製を描き直すため床の静的な部分も描き直す
  if T3DFxApplyMono(mono) then T3DWarp.dirty = true end
end

--- 常時自動: Miss したときの赤い縁
function T3DFxUpdateMiss(t)
  local miss = 0
  if Fx.missAt ~= nil and not T3DHide.AutoFx then
    local dt = t - Fx.missAt
    if dt >= 0 and dt < FxConf.MissEdgeMs then miss = FxConf.MissEdgeAlpha * (1 - dt / FxConf.MissEdgeMs) end
  end
  T3DSetA(Fx.boards.miss, T3DAlpha(miss))
end

--- 判定のたびに T3DScoreJudge から呼ぶ（常時自動の演出）
function T3DFxOnJudge(result, keepCombo)
  if T3DHide.AutoFx then return end
  local t = Game:Time()
  if result == JudgeType.Miss then
    if not keepCombo then Fx.missAt = t end
    return
  end
  local combo = T3DScore.combo
  if Fx.combo ~= nil and combo > 0 and combo % FxConf.ComboPulseStep == 0 and combo ~= Fx.comboShown then
    Fx.comboShown = combo
    local a = { start = t, finish = t + FxConf.ComboPulseMs, from = FxConf.ComboPulseFrom, to = 1 }
    Fx.combo:DoScale(a, a)
  end
end

--- リトライで演出を初期状態に戻す
function T3DResetFx()
  for kind in pairs(Fx.events) do Fx.index[kind] = 1 end
  Fx.glitchAt, Fx.shakeAt, Fx.noiseAt = -1, -1, -1
  Fx.missAt = nil
  Fx.comboShown = 0
  T3DWarp.shakeX, T3DWarp.shakeY, T3DWarp.waveAmp = 0, 0, 0
  T3DGlitchOff()
  T3DWarp.dirty = T3DWarp.on
  T3DWarp.on = false
  Fx.stampAt = {}
  for _, st in pairs(Fx.stamps) do
    for i = 1, st.n do
      st.born[i] = nil
      T3DSetA(st.q[i], 0)
    end
  end
end

--------------------------------------------------------------------------------
-- 複製（RGB ずれ・置き去り型の残像・追従型の尾）
--   ノーツの白いシルエット（fx-sil-tap / fx-sil-wipe）を t3d-lane グループの置き場に置く。
--   ノーツのコンテナの中に置くと、判定した瞬間に一緒に消えたり、使い回しで別のノーツに飛んだりする
--------------------------------------------------------------------------------

--- 置き場から1つ借りる。今フレームの分を使い切っていれば nil
function T3DFxTake(pl)
  if pl.used >= pl.n then return nil end
  pl.used = pl.used + 1
  return pl.q[pl.used]
end

--- Update のたびに呼ぶ。前の区切りで使ったが今回は使わなかった分を消す。
--- OnNoteMove が Update の前後どちらで呼ばれても、Update から次の Update までを1フレームとして数える
function T3DFxPoolFrame(pl)
  for i = pl.used + 1, pl.prev do T3DSetA(pl.q[i], 0) end
  pl.prev = pl.used
  pl.used = 0
end

--- 置き去り型の残像を薄くしていき、寿命が来たら消す
function T3DFxUpdateStamps(t)
  local life = FxConf.StampLifeMs
  for _, st in pairs(Fx.stamps) do
    for i = 1, st.n do
      local b = st.born[i]
      if b ~= nil then
        local age = t - b
        if age < 0 or age >= life then
          st.born[i] = nil
          T3DSetA(st.q[i], 0)
        else
          T3DSetA(st.q[i], T3DAlpha(st.a0[i] * (1 - age / life)))
        end
      end
    end
  end
end

--- Fx.lastV の4頂点を dx だけ横にずらして書く
function T3DFxPut(q, dx)
  local v = Fx.lastV
  q:SetVertex(0, v[1] + dx, v[2])
  q:SetVertex(1, v[3] + dx, v[4])
  q:SetVertex(2, v[5] + dx, v[6])
  q:SetVertex(3, v[7] + dx, v[8])
end

--- RGB ずれ: 直前に描いた部品（Fx.lastV）の赤とシアンの複製を、左右にずらして部品の後ろへ置く。
--- key は素材の種類（tap / wipe / long / bar / judge / white / beat）、alpha は元の部品の不透明度。
--- 呼ぶ側で Fx.rgbPx > 0 を確かめてから呼ぶ
function T3DRgbCopy(key, alpha, order)
  local off = Fx.rgbPx
  local a = T3DAlpha(FxConf.RgbAlpha * alpha / 100)
  local qr = T3DFxTake(Fx.pools[key .. 'R'])
  if qr ~= nil then
    T3DFxPut(qr, -off)
    T3DSetOrder(qr, order - 1)
    T3DSetA(qr, a)
  end
  local qc = T3DFxTake(Fx.pools[key .. 'C'])
  if qc ~= nil then
    T3DFxPut(qc, off)
    T3DSetOrder(qc, order - 1)
    T3DSetA(qc, a)
  end
end

--- ノーツの頭の複製。T3DNoteMove が頭を描いた直後に呼ぶ（Fx.lastV が頭の4頂点）。
--- single = 帯を持たない単発ノーツ（残像は単発だけ。Hold/Slide は帯と重なるので付けない）
function T3DFxHeadCopies(nid, key, alpha, order, single)
  if Fx.rgbPx > 0 then T3DRgbCopy(key, alpha, order) end
  if not single or Fx.afterA <= 0 then return end

  -- 置き去り型の残像: StampStepMs ごとに、その場にシルエットを置いていく
  local now = Fx.now
  local last = Fx.stampAt[nid]
  if last == nil or now - last >= FxConf.StampStepMs or now < last then
    Fx.stampAt[nid] = now
    local st = Fx.stamps[key]
    local i = st.next
    st.next = i % st.n + 1
    local q = st.q[i]
    local cc = FxConf.CopyColor
    T3DFxPut(q, 0)
    T3DFxTint(q, Fx.afterEv, cc[1], cc[2], cc[3])
    T3DSetOrder(q, order - 3)
    st.born[i], st.a0[i] = now, Fx.afterA
    T3DSetA(q, T3DAlpha(Fx.afterA))
  end
end

--------------------------------------------------------------------------------
-- モノクロ寄り（fx 行の mono）
--   ノーツ: OnDrawNote で灰色の素材に差し替える（毎フレームの負担なし）。
--           mono が 50 以上の間に「奥に現れた」ノーツが灰色になるので、灰色が奥から流れてくる
--   床・AirSlide: 白地に SetColor なので、色を輝度へ寄せて塗り直す（0.1 刻み）
--   左右のバー・判定線・空中判定線・AirTap: 灰色の複製を重ねて mono の値で濃くする
--   背景: 暗い灰色を被せる（背景の彩度そのものは下げられない）
--   TapEffect・判定表示は色を残す（アクセント）
--------------------------------------------------------------------------------

--- 色を輝度へ k (0〜1) だけ寄せる
function T3DFxGray(r, g, b, k)
  local l = 0.299 * r + 0.587 * g + 0.114 * b
  return { math.floor(r + (l - r) * k + 0.5), math.floor(g + (l - g) * k + 0.5), math.floor(b + (l - b) * k + 0.5) }
end

--- このノーツを灰色の素材で作るか。ノーツが奥に現れる時刻の mono で決める
function T3DFxMonoNote(info)
  if not T3D.Fx or not Fx.chartOn or T3DHide.ChartFx or Fx.events.mono == nil then return false end
  return (T3DFxHoldAt('mono', info.time - T3DLeadMs())) >= 50
end

--- mono の値を反映する。値が変わったら true（床の静的な部分を描き直す合図）
function T3DFxApplyMono(v)
  local changed = v ~= Fx.monoV
  Fx.monoV = v
  T3DFxBoardA('monoBg', T3DAlpha(FxConf.MonoBgAlpha * v / 100))
  local k = math.floor(v / 10 + 0.5) / 10
  if k ~= Fx.monoStep then
    Fx.monoStep = k
    -- 床のレーンの2色（T3DBuildFloor と同じ色）
    local c1, c2 = T3DFxGray(9, 11, 20, k), T3DFxGray(16, 20, 34, k)
    for j = 1, #T3DFloorQuads do
      for i = 1, T3DLanes do
        local c = (i % 2 == 0) and c2 or c1
        T3DFloorQuads[j][i]:SetColor(c[1], c[2], c[3])
      end
    end
    -- AirSlide（描くときに T3DSetTint で塗る）
    Fx.airFill = T3DFxGray(150, 115, 255, k)
    Fx.airEdge = T3DFxGray(202, 185, 255, k)
  end
  return changed
end

--- 灰色の複製を重ねる部品の、元の不透明度に掛ける係数。
--- 複製を上に重ねるだけだと、素材の半透明な縁（グロー）から下の色が透けて残るので、
--- 元を薄くして複製と入れ替える（mono 100 で元は消える）
function T3DFxMonoKeep()
  return 1 - Fx.monoV / 100
end

--- 床の部品の灰色の複製を、元と同じ矩形に描く。mono が 0 なら消す
function T3DFxMonoQuad(q, xl, xr, zn, zf, mirror, baseA)
  if q == nil then return end
  if Fx.monoV <= 0 then
    T3DSetA(q, 0)
  elseif T3DSetQuad(q, xl, xr, zn, zf, 0, mirror) then
    T3DSetA(q, T3DAlpha(baseA * Fx.monoV / 100))
  end
end

--- 床平面上の矩形(xl..xr, zn..zf)を投影して Grid に流し込む。
--- mirror=true は形はそのままでテクスチャだけ左右反転する（頂点への割り当てを入れ替える）。
--- 左右で対になる素材（トラックのバー）に使う
function T3DSetQuad(quad, xl, xr, zn, zf, y, mirror)
  if quad == nil then return false end
  local nlx, nly = T3DProject(xl, y, zn)
  local nrx, nry = T3DProject(xr, y, zn)
  local flx, fly = T3DProject(xl, y, zf)
  local frx, fry = T3DProject(xr, y, zf)
  if nlx == nil or nrx == nil or flx == nil or frx == nil then
    T3DSetA(quad, 0)
    return false
  end
  if mirror then
    nlx, nly, nrx, nry = nrx, nry, nlx, nly
    flx, fly, frx, fry = frx, fry, flx, fly
  end
  quad:SetVertex(0, nlx, nly)
  quad:SetVertex(1, nrx, nry)
  quad:SetVertex(2, flx, fly)
  quad:SetVertex(3, frx, fry)
  local v = Fx.lastV
  v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8] = nlx, nly, nrx, nry, flx, fly, frx, fry
  return true
end

--- 手前(xNear,zNear) と 奥(xFar,zFar) を幅 halfW でつないだ帯を描く。
--- Slide は途中で横に動くので、矩形専用の T3DSetQuad では表現できない
function T3DSetBand(quad, xNear, zNear, xFar, zFar, halfW, y, halfWFar)
  if quad == nil then return false end
  local hf = halfWFar or halfW   -- 奥側の半幅。省略すると手前と同じ（幅の変わる guide だけが渡す）
  local nlx, nly = T3DProject(xNear - halfW, y, zNear)
  local nrx, nry = T3DProject(xNear + halfW, y, zNear)
  local flx, fly = T3DProject(xFar  - hf, y, zFar)
  local frx, fry = T3DProject(xFar  + hf, y, zFar)
  if nlx == nil or nrx == nil or flx == nil or frx == nil then
    T3DSetA(quad, 0)
    return false
  end
  quad:SetVertex(0, nlx, nly)
  quad:SetVertex(1, nrx, nry)
  quad:SetVertex(2, flx, fly)
  quad:SetVertex(3, frx, fry)
  local v = Fx.lastV
  v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8] = nlx, nly, nrx, nry, flx, fly, frx, fry
  return true
end

--- 画面上で左端(l)から右端(r)へ伸びる横帯。テクスチャの横方向を線の向きに合わせる。
--- 空中判定線用。カメラの Roll で線が傾いても、太さは線に垂直な方向に付く
function T3DSetHBar(quad, lx, ly, ls, rx, ry, rs, halfT)
  if quad == nil then return false end
  local dx, dy = rx - lx, ry - ly
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.001 then return false end
  local nx, ny = -dy / len, dx / len   -- 線に垂直な「上」方向
  local tl, tr = halfT * ls, halfT * rs
  local v = Fx.lastV
  v[1], v[2], v[3], v[4] = lx - nx * tl, ly - ny * tl, rx - nx * tr, ry - ny * tr
  v[5], v[6], v[7], v[8] = lx + nx * tl, ly + ny * tl, rx + nx * tr, ry + ny * tr
  quad:SetVertex(0, v[1], v[2])
  quad:SetVertex(1, v[3], v[4])
  quad:SetVertex(2, v[5], v[6])
  quad:SetVertex(3, v[7], v[8])
  return true
end

--- 譜面x(0〜255) をワールドXに
function T3DWorldX(x)
  return (x / 255 - 0.5) * T3DTrackW
end

--------------------------------------------------------------------------------
-- TapEffect（v2 の slide-legacy-light-0〜15 を引き継ぐ）
--   実行時のテクスチャ差し替えは挙動が読めないので、16コマ分の Grid を
--   スロットごとに作っておき、Alpha で見せるコマを切り替える。
--------------------------------------------------------------------------------
function T3DBuildHitFx()
  for s = 1, HitFxConf.Slots do
    local frames = {}
    for f = 0, HitFxConf.Frames - 1 do
      local q = T3DGroup:AddGrid('t3d-fx-' .. s .. '-' .. f, HitFxConf.Tex .. f .. '.png')
      T3DSetOrder(q, 950)
      T3DSetA(q, 0)
      frames[f] = q
    end
    T3DHitFx[s] = { frames = frames, active = false, start = 0, x = 0, cur = -1 }
  end
end

--- 判定位置に TapEffect を出す。worldY は高さ（床は 0、空中判定線は T3DWorldY(255)）
function T3DSpawnHitFx(worldX, t, worldY)
  local slot = nil
  for s = 1, HitFxConf.Slots do
    if not T3DHitFx[s].active then
      slot = T3DHitFx[s]
      break
    end
  end
  if slot == nil then slot = T3DHitFx[1] end   -- 全部埋まっていたら一番古いものを潰す

  if slot.cur >= 0 and slot.frames[slot.cur] ~= nil then
    T3DSetA(slot.frames[slot.cur], 0)
  end
  slot.active = true
  slot.start = t
  slot.x = worldX
  slot.y = worldY or 0
  slot.cur = -1
end

--- 判定線上の1点を中心に、画面座標で正方形を置く。
--- 床に寝かせると奥行き方向に広がって判定線からはみ出すので、
--- カメラに正対させたまま判定線上に固定する（Roll にだけ追従させる）
function T3DSetBillboard(quad, cx, cy, halfSize)
  if quad == nil then return false end
  local r = math.rad(Cam.Roll)
  local cr, sr = math.cos(r), math.sin(r)
  -- 角 (dx, dy) = (±halfSize, ±halfSize) を Roll だけ回す
  local n, p = -halfSize, halfSize
  quad:SetVertex(0, cx + n * cr - n * sr, cy + n * sr + n * cr)
  quad:SetVertex(1, cx + p * cr - n * sr, cy + p * sr + n * cr)
  quad:SetVertex(2, cx + n * cr - p * sr, cy + n * sr + p * cr)
  quad:SetVertex(3, cx + p * cr - p * sr, cy + p * sr + p * cr)
  return true
end

function T3DUpdateHitFx(t)
  local half = (T3DTrackW / T3DLanes) * HitFxConf.Size * 0.5
  for s = 1, HitFxConf.Slots do
    local slot = T3DHitFx[s]
    if slot ~= nil and slot.active then
      local f = math.floor((t - slot.start) / HitFxConf.FrameMs)
      if f < 0 or f >= HitFxConf.Frames then
        if slot.cur >= 0 and slot.frames[slot.cur] ~= nil then
          T3DSetA(slot.frames[slot.cur], 0)
        end
        slot.active = false
        slot.cur = -1
      else
        if f ~= slot.cur then
          if slot.cur >= 0 and slot.frames[slot.cur] ~= nil then
            T3DSetA(slot.frames[slot.cur], 0)
          end
          slot.cur = f
        end
        local q = slot.frames[f]
        -- 判定線(z=0)上に投影し、そこを中心にする（空中なら空中判定線の高さ）
        local sx, sy, sc = T3DProject(slot.x, slot.y or 0, 0)
        if q ~= nil then
          if sx == nil then
            T3DSetA(q, 0)
          elseif T3DSetBillboard(q, sx, sy, half * sc) then
            T3DSetA(q, 100)
          end
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 判定表示（BEST / COOL / GOOD / MISS）
--   Composer の Judge モジュールは4種類のアニメをひとまとめに持っていて、
--   スクリプトからどれを再生するか選べない。そのため素材を直接 Grid で描く。
--   画面に固定するUIなので投影はしない。新しい判定が来たら前の表示を打ち切る。
--------------------------------------------------------------------------------
function T3DBuildJudgeText()
  for k = 1, #JudgeTextConf.Names do
    T3DJudgeText.frames[k] = {}
    for f = 0, JudgeTextConf.Frames - 1 do
      local tex = JudgeTextConf.Tex .. JudgeTextConf.Names[k] .. '-' .. f .. '.png'
      local q = T3DGroup:AddGrid('t3d-judgetext-' .. k .. '-' .. f, tex)
      T3DSetOrder(q, 980)
      T3DSetA(q, 0)
      T3DJudgeText.frames[k][f] = q
    end
  end
end

function T3DShowJudgeText(result, t)
  local jt = T3DJudgeText
  if jt.kind > 0 and jt.cur >= 0 then
    local q = jt.frames[jt.kind][jt.cur]
    if q ~= nil then T3DSetA(q, 0) end
  end
  jt.kind = result
  jt.start = t
  jt.cur = -1
end

function T3DUpdateJudgeText(t)
  local jt = T3DJudgeText
  if jt.kind <= 0 then return end

  -- コマごとに長さが違うので、頭から足して今のコマを探す（最大8回）
  local elapsed = t - jt.start
  local f, acc = 0, 0
  while f < JudgeTextConf.Frames do
    acc = acc + JudgeTextConf.FrameMs[f + 1]
    if elapsed < acc then break end
    f = f + 1
  end
  if elapsed < 0 then f = -1 end

  if f ~= jt.cur and jt.cur >= 0 then
    local old = jt.frames[jt.kind][jt.cur]
    if old ~= nil then T3DSetA(old, 0) end
  end
  if f < 0 or f >= JudgeTextConf.Frames then
    jt.kind = 0
    jt.cur = -1
    return
  end

  jt.cur = f
  local q = jt.frames[jt.kind][f]
  if q == nil then return end
  local hw, hh = 240 * JudgeTextConf.Scale, 90 * JudgeTextConf.Scale
  -- 空中判定線の画面上の高さは拡大率に比例して動くので、判定表示も一緒に動かす
  local ty = JudgeScreenY + SkyLineConf.ScreenOffset * T3DZoomNow + JudgeTextConf.Gap + hh
  q:SetVertex(0, -hw, ty - hh)
  q:SetVertex(1,  hw, ty - hh)
  q:SetVertex(2, -hw, ty + hh)
  q:SetVertex(3,  hw, ty + hh)
  T3DSetA(q, 100)
end

--------------------------------------------------------------------------------
-- Hold 中のエフェクト
--   押し続けている Hold/Slide ごとに1スロットを割り当て、判定線上で
--   その時点の Slide の位置を追いかけながらループ再生する。
--   T3DHolds から消えた（完走 / 途中離し）スロットは自動で解放される
--------------------------------------------------------------------------------
function T3DBuildHoldFx()
  for s = 1, HoldFxConf.Slots do
    local frames = {}
    for f = 0, HoldFxConf.Count - 1 do
      local q = T3DGroup:AddGrid('t3d-holdfx-' .. s .. '-' .. f, HitFxConf.Tex .. (HoldFxConf.First + f) .. '.png')
      T3DSetOrder(q, 945)
      T3DSetA(q, 0)
      frames[f] = q
    end
    T3DHoldFx[s] = { frames = frames, nid = nil, start = 0, cur = -1 }
  end
end

--- kind = 'floor' なら ref は押下中の床 Hold の nid、'air' なら AirSlide の区間そのもの
function T3DAttachHoldFx(kind, ref, t)
  for s = 1, HoldFxConf.Slots do
    local slot = T3DHoldFx[s]
    if slot ~= nil and slot.ref == nil then
      slot.kind = kind
      slot.ref = ref
      slot.start = t
      slot.cur = -1
      return
    end
  end
end

function T3DUpdateHoldFx(now)
  local half = (T3DTrackW / T3DLanes) * HoldFxConf.Size * 0.5
  for s = 1, HoldFxConf.Slots do
    local slot = T3DHoldFx[s]

    -- 今エフェクトを出す位置。対象が終わっていたら nil
    local wx, wy = nil, 0
    if slot.kind == 'floor' and slot.ref ~= nil then
      local h = T3DHolds[slot.ref]
      -- 切れている間はエフェクトを出さない（復活時に付け直す）
      if h ~= nil and not h.broken then wx = T3DWorldX(T3DSlideXAt(h.info, now)) end
    elseif slot.kind == 'air' and slot.ref ~= nil then
      local r = slot.ref
      if r.state == 'active' and now >= r.s and now <= r.e then
        local x, y = T3DAirSlidePos(r, now)
        wx, wy = T3DWorldX(x), T3DWorldY(y)
      end
    end

    if wx == nil then
      if slot.cur >= 0 then T3DSetA(slot.frames[slot.cur], 0) end
      slot.kind = nil
      slot.ref = nil
      slot.cur = -1
    else
      local f = math.floor((now - slot.start) / HoldFxConf.FrameMs) % HoldFxConf.Count
      if f ~= slot.cur and slot.cur >= 0 then
        T3DSetA(slot.frames[slot.cur], 0)
      end
      slot.cur = f
      local q = slot.frames[f]
      local sx, sy, sc = T3DProject(wx, wy, 0)
      if sx == nil then
        T3DSetA(q, 0)
      elseif T3DSetBillboard(q, sx, sy, half * sc) then
        T3DSetA(q, 100)
      end
    end
  end
end

--------------------------------------------------------------------------------
-- フリック矢印
--------------------------------------------------------------------------------

--- フリックの矢印テクスチャを返す。フリックでなければ nil。
--- info.arrow は 1=左 2=上 3=右。譜面ファイル上の dir(2/4/8) で来た場合も読み替える
function T3DFlickTex(info)
  if info.type ~= 5 and info.type ~= 6 then return nil end
  local a = info.arrow
  if a == 4 then
    a = 2
  elseif a == 8 then
    a = 3
  end
  if a == nil or a < 1 or a > 3 then a = 2 end
  if info.type == 6 then a = a + 3 end
  return FlickConf.Tex .. a .. '.png', a
end

--------------------------------------------------------------------------------
-- 床（レーン・左右バー・判定線・空中判定線）
--------------------------------------------------------------------------------
--- 床を奥行き方向に区切る境界の z 一覧。
--- [手前端, 0(判定線), 奥へ二乗間隔で T3DFloorFar まで]。行数 = 要素数 - 1 = T3DSlices + 1
function T3DFloorBounds()
  local b = { T3DFloorNear, 0 }
  for j = 1, T3DSlices do
    b[#b + 1] = T3DFloorFar * (j / T3DSlices) ^ 2
  end
  return b
end

--- 奥の端に向かってフェードする係数（T3DDepth までは 1）
function T3DFloorFade(z)
  if z <= T3DDepth then return 1 end
  local f = 1 - (z - T3DDepth) / (T3DFloorFar - T3DDepth)
  if f < 0 then return 0 end
  return f
end

--------------------------------------------------------------------------------
-- 小節線
--   譜面ファイルに小節の区切りが無いので、拡張ファイルの measure 行で決める。
--   BPM 変化に追従させるため、BPM の記録から「時刻 <-> 曲頭からの拍」を引けるようにする
--------------------------------------------------------------------------------

--- BPM の記録を集めて、各区間の先頭までの累積拍を持たせる
function T3DBuildBpmTable()
  local list = {}
  pcall(function()
    local n = Chart:BpmCount()
    for i = 0, n - 1 do
      local b = Chart:BpmAt(i)
      if b ~= nil and b.bpm ~= nil and b.bpm > 0 then
        list[#list + 1] = { time = b.time or 0, bpm = b.bpm }
      end
    end
  end)
  table.sort(list, function(a, b) return a.time < b.time end)
  if #list == 0 then list[1] = { time = 0, bpm = 120 } end
  -- 最初の記録より前の区間は同じ BPM だったものとして扱う
  if list[1].time > 0 then
    table.insert(list, 1, { time = 0, bpm = list[1].bpm })
  end
  list[1].beat = 0
  for i = 2, #list do
    local p = list[i - 1]
    list[i].beat = p.beat + (list[i].time - p.time) * p.bpm / 60000
  end
  T3DBpmTable = list
end

--- その時刻が曲頭から何拍目か
function T3DBeatAt(t)
  local list = T3DBpmTable
  if list == nil then return 0 end
  local seg = list[1]
  for i = 1, #list do
    if list[i].time <= t then seg = list[i] else break end
  end
  return seg.beat + (t - seg.time) * seg.bpm / 60000
end

--- 拍 -> 時刻(ms)
function T3DTimeAtBeat(b)
  local list = T3DBpmTable
  if list == nil then return 0 end
  local seg = list[1]
  for i = 1, #list do
    if list[i].beat <= b then seg = list[i] else break end
  end
  return seg.time + (b - seg.beat) * 60000 / seg.bpm
end

function T3DBuildMeasure()
  for i = 1, MeasureConf.Pool do
    local q = T3DGroup:AddGrid('t3d-measure-' .. i, MeasureConf.Tex)
    T3DSetOrder(q, 12)          -- 床(3〜9)より手前、影(16)やバー(18)より奥
    T3DSetA(q, 0)
    T3DMeasureQuads[i] = q
  end
  print(string.format('[T3D] 小節線: 開始Beat=%.3f 1小節=%.3f拍 BPM記録=%d',
    MeasureStartBeat, MeasureBeats, T3DBpmTable ~= nil and #T3DBpmTable or 0))
end

--- 小節線1本を描く（プールの n 本目）。描いたら true
function T3DDrawMeasureAt(n, z, half)
  local q = T3DMeasureQuads[n]
  if T3DSetQuad(q, -half, half, z - MeasureConf.HalfZ, z + MeasureConf.HalfZ, 0) then
    T3DSetA(q, MeasureConf.Alpha)
    if Fx.rgbPx > 0 then T3DRgbCopy('beat', MeasureConf.Alpha, 12) end
  end
end

--- 見えている範囲の小節線だけをプールの Grid に割り当てて描く
function T3DUpdateMeasure(t)
  local half = T3DTrackW * 0.5
  local n = 0
  local list = T3DVirt.measure
  if T3DVirt.ok and #list > 0 then
    -- 仮想ノーツの位置で描く。3秒前より後の小節線から見て、まだエンジンが出していない
    -- （奥にある）ものに当たったら打ち切る
    local L, R = 1, #list + 1
    while L < R do
      local mid = math.floor((L + R) / 2)
      if list[mid] < t - 3000 then L = mid + 1 else R = mid end
    end
    local g = T3DVirt.measureG
    for i = L, #list do
      if n >= MeasureConf.Pool then break end
      local z = T3DElemZ(list[i], t, g)
      if z >= T3DFarZ and list[i] > t then break end
      if z >= T3DFloorNear and z <= T3DDepth then
        n = n + 1
        T3DDrawMeasureAt(n, z, half)
      end
    end
  -- 速度を実測できるまでは出さない。既定値のまま流すと、最初の数秒だけ
  -- ノーツと違う速さで小節線が動いてしまう
  elseif T3DScrollMeasured and MeasureBeats > 0 and T3DBpmTable ~= nil and T3DScrollWindow > 0 then
    -- 今より1つ手前の小節から見て、判定線の手前から出現位置までに入るものを拾う
    local k = math.floor((T3DBeatAt(t) - MeasureStartBeat) / MeasureBeats) - 1
    local guard = 0
    while n < MeasureConf.Pool and guard < MeasureConf.Pool * 4 do
      guard = guard + 1
      local z = T3DTimeZ(T3DTimeAtBeat(MeasureStartBeat + k * MeasureBeats), t)
      k = k + 1
      if z > T3DDepth then break end
      if z >= T3DFloorNear then
        n = n + 1
        T3DDrawMeasureAt(n, z, half)
      end
    end
  end
  for i = n + 1, MeasureConf.Pool do
    local q = T3DMeasureQuads[i]
    if q ~= nil then T3DSetA(q, 0) end
  end
end

function T3DBuildFloor()
  local rows = T3DSlices + 1
  for j = 1, rows do
    T3DFloorQuads[j] = {}
    for i = 1, T3DLanes do
      local q = T3DGroup:AddGrid('t3d-floor-' .. j .. '-' .. i, T3DTex)
      -- 奥の行から先に描く（ペインターズアルゴリズム）。床は他のどの要素より奥
      T3DSetOrder(q, 3 + (rows - j))
      T3DSetA(q, T3DFloorAlpha)
      -- v2 のトラックに合わせた暗色。レーン境界が分かる程度の差だけ付ける
      if i % 2 == 0 then
        q:SetColor(16, 20, 34)
      else
        q:SetColor(9, 11, 20)
      end
      T3DFloorQuads[j][i] = q
    end
  end

  -- トラック左右の発光バー（v2 の Track-Bar-Left/Right 相当）
  for j = 1, rows do
    T3DTrackBars[j] = {}
    for side = 1, 2 do
      local q = T3DGroup:AddGrid('t3d-trackbar-' .. j .. '-' .. side, TexTrack)
      T3DSetOrder(q, 10 + T3DSlices + 2)
      T3DSetA(q, 0)
      T3DTrackBars[j][side] = q
    end
  end

  -- 床のキーを押している間光るレーン（PC での確認用）
  for i = 1, T3DLanes do
    local q = T3DGroup:AddGrid('t3d-lanelight-' .. i, T3DTex)
    T3DSetOrder(q, 10 + T3DSlices + 1)   -- 床より手前、ノーツより奥
    T3DSetA(q, 0)
    q:SetColor(120, 230, 255)
    T3DLaneQuads[i] = q
  end

  local jl = T3DGroup:AddGrid('t3d-judgeline', TexJudge)
  T3DSetOrder(jl, 10 + T3DSlices + 3)
  T3DSetA(jl, 100)
  T3DFloorQuads.JudgeLine = jl

  -- 空中判定線（AirSlide・AirTap用）。床の判定線の真上 y=255 の高さに張る。
  -- AirSlide(Order〜700)より手前、判定線付近のAirTap(Order〜760)より奥
  local sl = T3DGroup:AddGrid('t3d-skyline', TexJudge)
  T3DSetOrder(sl, 720)
  T3DSetA(sl, 0)
  T3DFloorQuads.SkyLine = sl

  -- 空中のキー(Q W E R)を押している間だけ、空中判定線の該当するレーンを光らせる（PC確認用）
  T3DFloorQuads.AirLane = {}
  for i = 1, T3DLanes do
    local q = T3DGroup:AddGrid('t3d-skylane-' .. i, T3DTex)
    T3DSetOrder(q, 721)
    T3DSetA(q, 0)
    T3DAirSlideColor(q, true)
    T3DFloorQuads.AirLane[i] = q
  end
end

-- 床・左右バー・判定線を最後に投影したときのカメラ。
-- この3つはカメラが動かない限り画面上の形が変わらないので、変わったときだけ投影し直す
-- （cam 行の無い譜面では最初の1回だけになる）
local T3DFloorCam = {}

--- 前回床を投影したときからカメラが動いたか。動いていれば今の値を覚える
function T3DFloorCamChanged()
  local c = T3DFloorCam
  if c.X == Cam.X and c.Y == Cam.Y and c.Z == Cam.Z and c.Pitch == Cam.Pitch
      and c.Roll == Cam.Roll and c.Focal == Cam.Focal and c.ShiftY == Cam.ShiftY
      and c.px == T3DRollPivotX and c.py == T3DRollPivotY and c.near == T3DFloorNear then
    return false
  end
  c.X, c.Y, c.Z, c.Pitch, c.Roll, c.Focal, c.ShiftY = Cam.X, Cam.Y, Cam.Z, Cam.Pitch, Cam.Roll, Cam.Focal, Cam.ShiftY
  c.px, c.py, c.near = T3DRollPivotX, T3DRollPivotY, T3DFloorNear
  return true
end

function T3DUpdateFloor(t)
  local half = T3DTrackW * 0.5
  if T3DFloorCamChanged() or T3DWarp.dirty then T3DUpdateFloorStatic(half) end
  T3DUpdateFloorDynamic(t, half)
end

--- 床・左右バー・判定線。カメラが動いたときだけ呼ぶ
function T3DUpdateFloorStatic(half)
  local bounds = T3DFloorBounds()
  for j = 1, #bounds - 1 do
    -- 判定線の手前は画面下端まで、奥は T3DDepth の先まで伸ばしてフェードさせる
    local zn, zf = bounds[j], bounds[j + 1]
    local fade = T3DFloorFade((zn + zf) * 0.5)
    for i = 1, T3DLanes do
      local xl = -half + T3DTrackW * (i - 1) / T3DLanes
      local xr = -half + T3DTrackW * i / T3DLanes
      local q = T3DFloorQuads[j][i]
      if T3DSetQuad(q, xl, xr, zn, zf, 0) then
        T3DSetA(q, T3DAlpha(T3DFloorAlpha * fade))
      end
    end

    -- 左右の発光バー
    local bars = T3DTrackBars[j]
    if bars ~= nil then
      -- 素材は片側だけが不透明（62px のうち左 41px）。左のバーは反転させないと
      -- 透明な側がレーンに接して隙間になる
      if T3DSetQuad(bars[1], -half - T3DBarWidth, -half, zn, zf, 0, true) then
        T3DSetA(bars[1], T3DAlpha(100 * fade * T3DFxMonoKeep()))
        if Fx.rgbPx > 0 then T3DRgbCopy('bar', T3DAlpha(100 * fade), 10 + T3DSlices + 2) end
      end
      if T3DSetQuad(bars[2], half, half + T3DBarWidth, zn, zf, 0) then
        T3DSetA(bars[2], T3DAlpha(100 * fade * T3DFxMonoKeep()))
        if Fx.rgbPx > 0 then T3DRgbCopy('bar', T3DAlpha(100 * fade), 10 + T3DSlices + 2) end
      end
    end
    local mb = Fx.monoBars[j]
    if mb ~= nil then
      T3DFxMonoQuad(mb[1], -half - T3DBarWidth, -half, zn, zf, true, 100 * fade)
      T3DFxMonoQuad(mb[2], half, half + T3DBarWidth, zn, zf, false, 100 * fade)
    end
  end
  -- 判定線。床の上の矩形として描く。左右の端はワールドXが一定なので、
  -- 投影するとレーンの境界の斜め線にそのまま乗る（画面上の横帯にすると端が垂直に切れて
  -- 上側の角が斜め線から飛び出す）。幅はレーンの黒い下地と同じで、バーの手前で切る
  local jOut = half + T3DBarWidth * JudgeLineReach
  local jl = T3DFloorQuads.JudgeLine
  if T3DSetQuad(jl, -jOut, jOut, -JudgeLineHalfZ, JudgeLineHalfZ, 0) then
    T3DSetA(jl, T3DAlpha(100 * T3DFxMonoKeep()))
    if Fx.rgbPx > 0 then T3DRgbCopy('judge', 100, 10 + T3DSlices + 3) end
  end
  T3DFxMonoQuad(Fx.monoJudge, -jOut, jOut, -JudgeLineHalfZ, JudgeLineHalfZ, false, 100)
end

--- 空中判定線と押下中のレーンの光。点滅や押下で毎フレーム変わる
function T3DUpdateFloorDynamic(t, half)
  if T3DFloorQuads.SkyLine ~= nil then T3DUpdateSkyLine(t, half) end
  T3DUpdateFloorLanes(half)
end

--- 空中判定線: 床の判定線(z=0)の真上、拡張ファイルの y=255 の高さ。押されている空中のレーンも光らせる
function T3DUpdateSkyLine(t, half)
  local sky = T3DFloorQuads.SkyLine
  local skyH = T3DWorldY(255)
  -- 普段は消えていて、空中要素が来る前に点滅してから点灯する。消えている間は投影もしない
  local skyA = T3D.Air and T3DSkyLineAlpha(t) or 0
  local shown = false
  local monoA = 0
  if skyA > 0 then
    local lx, ly, ls = T3DProject(-half - T3DBarWidth, skyH, 0)
    local rx, ry, rs = T3DProject( half + T3DBarWidth, skyH, 0)
    shown = lx ~= nil and rx ~= nil and T3DSetHBar(sky, lx, ly, ls, rx, ry, rs, SkyLineConf.HalfT)
    if shown and Fx.rgbPx > 0 then T3DRgbCopy('judge', skyA, 720) end
    -- モノクロ: 灰色の複製を重ねる
    if shown and Fx.monoSky ~= nil and Fx.monoV > 0
        and T3DSetHBar(Fx.monoSky, lx, ly, ls, rx, ry, rs, SkyLineConf.HalfT) then
      monoA = T3DAlpha(skyA * Fx.monoV / 100)
    end
  end
  T3DSetA(sky, shown and T3DAlpha(skyA * T3DFxMonoKeep()) or 0)
  if Fx.monoSky ~= nil then T3DSetA(Fx.monoSky, monoA) end

  -- 押されている空中のレーンを光らせる
  local airLanes = T3DFloorQuads.AirLane
  if airLanes ~= nil then
    for i = 1, T3DLanes do
      local q = airLanes[i]
      local a = 0
      if T3D.Air and T3DAirLaneDown[i] then
        local xl = -half + T3DTrackW * (i - 1) / T3DLanes
        local xr = -half + T3DTrackW * i / T3DLanes
        local ax, ay, as = T3DProject(xl, skyH, 0)
        local bx, by, bs = T3DProject(xr, skyH, 0)
        if ax ~= nil and bx ~= nil and T3DSetHBar(q, ax, ay, as, bx, by, bs, SkyLineConf.HalfT * 4) then
          a = 45
        end
      end
      T3DSetA(q, a)
    end
  end
end

--- 押されている床のレーンを光らせる
function T3DUpdateFloorLanes(half)
  for i = 1, T3DLanes do
    local q = T3DLaneQuads[i]
    if q ~= nil then
      if T3DLaneDown[i] then
        local xl = -half + T3DTrackW * (i - 1) / T3DLanes
        local xr = -half + T3DTrackW * i / T3DLanes
        if T3DSetQuad(q, xl + 8, xr - 8, 0, 500, 0) then
          T3DSetA(q, 65)
        end
      else
        T3DSetA(q, 0)
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 空中要素（AirSlide / AirTap）
--
-- AirSlideはエンジンのノーツではないので p が貰えない。そこで「時刻->奥行き」を
-- 実測した T3DScrollWindow から自前で計算し、床のノーツと同じ速度で流す。
--
-- 拡張ファイル(lane3d.ex / chart_3d.ex)の書式:
--   # 行頭 # はコメント
--   airlift,開始ms,終了ms,x,up|down[,ease[,幅]]   床 <-> 空中判定線 の縦移動（x 固定）
--   airslide,開始ms,終了ms,x1,x2[,ease[,幅]]      空中判定線の上での横移動
--   airtap,時刻ms,x[,幅]                          空中判定線の上の単発
--     x と幅は 0〜255 の自由座標（床ノーツと同じ）。幅を省略すると AirConf.DefaultWidth
--     ease  0=直線 1=イン 2=アウト 3=インアウト
--   measure,開始Beat[,1小節の拍数]                小節線（ファイル全体に1回）
--   cam,開始ms,終了ms,項目,開始値,終了値[,ease]  カメラ演出（項目 = angle/x/y/z/roll/zoom）
--
-- 空中要素の規約（読込時にチェックする）:
--   A. 高さは「床」と「空中判定線」の2段だけ。中間の高さで止まる・動くことはない
--      （宙に浮いた物と床の奥にある物が画面上で同じ位置に来て、読み分けられないため）
--   B. AirSlide の区間は縦(airlift)か横(airslide)のどちらか。斜めは無い
--   D. AirTap を AirSlide に重ねるなら、端点か継ぎ目だけ（途中は取る場所が曖昧になる）
--      -> A・B は書式上そもそも書けない。D の違反は読み込まない
--   C. 目安（違反してもログに警告を出すだけ）
--      Lift は 1/4 拍以上 / Slide は 1拍あたり2レーンまで / 1区間は 1/8 拍以上
--   E. 画面内の AirSlide は同時に2本まで（超えたら警告）
--
-- 当たりは床と同じ。空中判定線の上で、ポインタの位置が要素の幅の中なら取れる。
-- タッチは空中判定線の上の位置を逆算し、PC のキーは Q W E R が空中の4レーンになる。
-- 縦移動(Lift)の間だけは、床の同じ位置・幅を押していても取れる
--------------------------------------------------------------------------------

--- そのノーツグループのスクロール速度。書かれていなければ 1
function T3DHsOf(group)
  if group == nil then return 1 end
  local v = T3DHs[group]
  if v == nil then return 1 end
  return v
end

--------------------------------------------------------------------------------
-- TimingGroup
--   区間 pc = { s = 始まり, base = s での位置, rs〜re = 速度が v0 から v1 へ変わる区間, ease }
--   速度 S(x) は rs より前は v0、re より後は v1、間は ease で補間。位置は S の積分。
--   ease は3次以下の多項式なので、区間内の積分はシンプソン則1回で厳密に求まる
--------------------------------------------------------------------------------

function T3DTgVal(pc, x)
  if x >= pc.re then return pc.v1 end
  if x <= pc.rs then return pc.v0 end
  return pc.v0 + (pc.v1 - pc.v0) * T3DEase((x - pc.rs) / (pc.re - pc.rs), pc.ease)
end

--- 区間 pc の速度を a から b まで積分する（a > b なら負）
function T3DTgInt(pc, a, b)
  if a == b then return 0 end
  local sign = 1
  if a > b then a, b, sign = b, a, -1 end
  local sum = 0
  if a < pc.rs then
    local e = math.min(b, pc.rs)
    sum = sum + pc.v0 * (e - a)
    a = e
  end
  if a < b and a < pc.re then
    local e = math.min(b, pc.re)
    local m = (a + e) * 0.5
    sum = sum + (e - a) / 6 * (T3DTgVal(pc, a) + 4 * T3DTgVal(pc, m) + T3DTgVal(pc, e))
    a = e
  end
  if a < b then sum = sum + pc.v1 * (b - a) end
  return sign * sum
end

function T3DTgPosIn(pc, t)
  return pc.base + T3DTgInt(pc, pc.s, t)
end

--- 時刻 t での位置（ms 単位。scroll 1 なら時刻と同じだけ進む）
function T3DTgPos(tg, t)
  local ps = tg.ps
  local L, R = 1, #ps
  while L < R do                        -- s <= t となる最後の区間
    local mid = math.floor((L + R + 1) / 2)
    if ps[mid].s <= t then L = mid else R = mid - 1 end
  end
  return T3DTgPosIn(ps[L], t)
end

--- 読み込んだ timinggroup 行を区間の列にする（Init で1回）
function T3DCommitTg()
  for g, list in pairs(T3DTg.raw) do
    table.sort(list, function(a, b)
      if a.t ~= b.t then return a.t < b.t end
      return a.order < b.order
    end)
    T3DTg.groups[g] = T3DTgBuild(list)
  end
  T3DTg.raw = {}
end

--- 時刻順に並べた行 { t, kind = 'scroll' / 'jump', v, e, ease } の列から、区間の列を作る
--- （timinggroup と、LegacyMode の譜面の effect で共通）
function T3DTgBuild(list)
    local cur = { s = 0, base = 0, rs = 0, re = 0, v0 = 1, v1 = 1, ease = 0 }
    local ps = { cur }
    local mono = true
    for _, r in ipairs(list) do
      local pos = T3DTgPosIn(cur, r.t)
      local v = T3DTgVal(cur, r.t)
      local nx
      if r.kind == 'jump' then
        -- エンジンと同じく「ms x その瞬間の scroll」だけ跳ぶ。速度の変化の途中なら、そのまま続く
        nx = { s = r.t, base = pos + r.v * v, rs = cur.rs, re = cur.re, v0 = cur.v0, v1 = cur.v1, ease = cur.ease }
      elseif r.e ~= nil and r.e > r.t then
        -- 今の値から ease で変える。変化の途中で次の行が来たら、そこでの値から次の行が引き継ぐ
        nx = { s = r.t, base = pos, rs = r.t, re = r.e, v0 = v, v1 = r.v, ease = r.ease }
      else
        nx = { s = r.t, base = pos, rs = r.t, re = r.t, v0 = r.v, v1 = r.v, ease = 0 }
      end
      if nx.v0 < 0 or nx.v1 < 0 then nx.neg = true end
      if r.kind == 'jump' and r.v * v < 0 then nx.negJump = true end
      if nx.neg or nx.negJump then mono = false end
      ps[#ps + 1] = nx
      cur = nx
    end
    return { ps = ps, mono = mono, lines = #list }
end

--- 時刻 a〜b の間に「位置が戻る」ところ（負の速度・後ろ向きの jump）があるか
function T3DTgSpanBack(tg, a, b)
  local ps = tg.ps
  local L, R = 1, #ps
  while L < R do                        -- a を含む区間
    local mid = math.floor((L + R + 1) / 2)
    if ps[mid].s <= a then L = mid else R = mid - 1 end
  end
  for i = L, #ps do
    local pc = ps[i]
    if pc.s > b then break end
    if pc.neg then
      -- 区間の中で実際に負になるか。速度は区間の中で単調（ease も単調）なので両端を見れば足りる
      local e = b
      if i < #ps and ps[i + 1].s < e then e = ps[i + 1].s end
      local st = math.max(a, pc.s)
      if T3DTgVal(pc, st) < 0 or T3DTgVal(pc, e) < 0 then return true end
    end
    if pc.negJump and pc.s > a then return true end
  end
  return false
end

--- そのグループの TimingGroup（無ければ nil）
function T3DTgOf(group)
  if group == nil then return nil end
  return T3DTg.groups[group]
end

--- エンジンの窓(ms)。TimingGroup の位置を「残り」に直すのに使う
function T3DEngineWindow()
  return T3DScrollWindow
end

-- TimingGroup のノーツに渡す「p の代わり」。エンジンの p と同じく [i] で 1 - 残り を返す。
-- 読まれた点だけ計算する（中継点が数百ある Slide でも、二分探索で読む数点だけで済む）
local T3DTgQ = setmetatable({ Length = 0 }, { __index = function(q, i)
  if type(i) ~= 'number' then return nil end
  local c = q.c
  local v = c[i]
  if v == nil then
    local t = T3DSegPoint(c.segs, i)
    v = T3DTgPos(c.tg, t)
    c[i] = v
  end
  return 1 - (v - q.pnow) * q.invW
end })

--- TimingGroup のノーツの「p の代わり」を用意する。len はエンジンの p.Length
function T3DTgProgress(info, tg, segs, len)
  local t = T3DTg.nowT
  if t == nil then t = Game:Time() end
  local pnow = T3DTg.now[tg]
  if pnow == nil then
    pnow = T3DTgPos(tg, t)
    T3DTg.now[tg] = pnow
  end
  local c = T3DTg.cache[info.nid]
  if c == nil or c.tg ~= tg then
    c = { tg = tg, segs = segs, back = false }
    -- 帯を持つノーツは、自分の時間の中で位置が戻るときだけ「順に見る」描き方にする
    if not tg.mono and segs.n > 0 then
      local tEnd = T3DSegPoint(segs, segs.n)
      c.back = T3DTgSpanBack(tg, segs.t0, tEnd)
    end
    T3DTg.cache[info.nid] = c
  end
  local q = T3DTgQ
  q.c, q.pnow, q.Length = c, pnow, len
  local w = T3DEngineWindow()
  if w < 1 then w = 1 end
  q.invW = 1 / w
  return q, c.back
end

--- 毎フレームの頭で「今」を更新する（位置はこのフレームの中で使い回す）
function T3DTgFrame(t)
  if T3DTg.nowT ~= t then
    T3DTg.nowT = t
    T3DTg.now = {}
  end
end

--------------------------------------------------------------------------------
-- 小節線・空中要素の奥行き
--   グループ指定（group=）があり、そのグループに timinggroup 行があれば、その速度の積分から出す。
--   それ以外は仮想ノーツの p から出す（譜面の scroll・停止・逆走・jump に床のノーツと同じく従う）。
--   仮想ノーツが使えなければ、従来どおり時刻から出す
--------------------------------------------------------------------------------
--- 時刻 t の小節線・空中要素の奥行き（ワールドZ）。g はグループ（無ければ nil）
function T3DElemZ(t, now, g)
  local k = T3DDepth * T3DSpeed
  if g ~= nil then k = k * T3DHsOf(g) end
  local tg = T3DTgOf(g)
  if tg ~= nil then
    if not T3DScrollMeasured then return T3DFarZ end
    local pnow = T3DTg.now[tg]
    if pnow == nil then
      pnow = T3DTgPos(tg, now)
      T3DTg.now[tg] = pnow
    end
    return (T3DTgPos(tg, t) - pnow) / T3DEngineWindow() * k
  end
  if not T3DVirt.ok then
    if not T3DScrollMeasured then return T3DFarZ end
    return T3DTimeZ(t, now) * (k / (T3DDepth * T3DSpeed))
  end
  local rec = T3DVirt.byT[math.floor(t + 0.5)]
  if rec == nil or rec.at == nil then
    -- エンジンがまだ出していない（奥）か、出す前に通り過ぎた
    if t > now then return T3DFarZ end
    return -T3DFarZ
  end
  local dt = now - rec.at
  if dt > 100 then
    -- エンジンが出すのをやめた。p < 0（奥へ戻った）か p > 1.25（通り過ぎた）
    if rec.rem > 0.5 then return T3DFarZ end
    return -T3DFarZ
  end
  if dt < 0 then dt = 0 end
  if dt > 50 then dt = 50 end
  return (rec.rem - dt * T3DVirt.rate) * k
end

--- ノーツが見えている時間(ms)。実測した窓を T3DSpeed で割ったもの
function T3DLeadMs()
  return T3DScrollWindow / T3DSpeed
end

--- 時刻 -> ワールドZ。判定時刻で 0、出現時点で T3DDepth
function T3DTimeZ(t, now)
  local lead = T3DLeadMs()
  if lead <= 0 then return T3DDepth end
  return ((t - now) / lead) * T3DDepth
end

--- 拡張ファイルの y(0〜255) -> ワールドの高さ
function T3DWorldY(y)
  return (y / 255) * T3DHeightMax
end

function T3DEase(u, kind)
  if u < 0 then u = 0 end
  if u > 1 then u = 1 end
  if kind == 1 then
    return u * u
  elseif kind == 2 then
    return 1 - (1 - u) * (1 - u)
  elseif kind == 3 then
    return u * u * (3 - 2 * u)
  end
  return u
end

--- AirSlide の色（単色）。edge = true なら縁取り用に白へ寄せた明るい色
function T3DAirSlideColor(q, edge)
  local r, g, b = 150, 115, 255
  if edge then
    -- SetColor も整数しか受け付けない（小数は 0 扱いになる）ので切り捨てる
    r, g, b = math.floor((r + 255) * 0.5), math.floor((g + 255) * 0.5), math.floor((b + 255) * 0.5)
  end
  q:SetColor(r, g, b)
end

--- 高さを持つ平らな帯。手前(xa,ya,za) と 奥(xb,yb,zb) を、
--- ワールド空間で水平な幅 halfW の板としてつなぐ（AirSlide 用）
function T3DSetBand3(quad, xa, ya, za, xb, yb, zb, halfW)
  if quad == nil then return false end
  local nlx, nly = T3DProject(xa - halfW, ya, za)
  local nrx, nry = T3DProject(xa + halfW, ya, za)
  local flx, fly = T3DProject(xb - halfW, yb, zb)
  local frx, fry = T3DProject(xb + halfW, yb, zb)
  if nlx == nil or nrx == nil or flx == nil or frx == nil then
    T3DSetA(quad, 0)
    return false
  end
  quad:SetVertex(0, nlx, nly)
  quad:SetVertex(1, nrx, nry)
  quad:SetVertex(2, flx, fly)
  quad:SetVertex(3, frx, fry)
  local v = Fx.lastV
  v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8] = nlx, nly, nrx, nry, flx, fly, frx, fry
  return true
end

--- 空中要素の描画プールを作る。
--- AirSlideは「外側の光の膜」「明るい芯」「床に落ちる影」の3層。
--- 影があることで空間内の位置が分かり、床ノーツと同じ速さで動くので本当の速度も見える
--- 空中要素の描画プールを作る。T3DCommitAir の後に呼ぶ（譜面に無い種類は作らない）。
--- 見えない Grid も毎フレームの描画に効くので、空中要素の無い譜面では1枚も作らない
function T3DBuildAir()
  local slidePool = (#T3DAirSlides > 0) and AirConf.SlidePool or 0
  local tapPool = (#T3DAirTaps > 0) and AirConf.TapPool or 0
  for a = 1, slidePool do
    local layers = { fill = {}, edgeL = {}, edgeR = {}, shadow = {} }
    for i = 1, AirConf.SlideSamples do
      local sh = T3DGroup:AddGrid('t3d-airslide-shadow-' .. a .. '-' .. i, T3DTex)
      sh:SetColor(0, 0, 0)
      T3DSetA(sh, 0)
      layers.shadow[i] = sh

      -- 色は変わらないので、ここで1回だけ塗る（毎フレーム SetColor すると C# 呼び出しがかさむ）
      local fi = T3DGroup:AddGrid('t3d-airslide-fill-' .. a .. '-' .. i, T3DTex)
      T3DAirSlideColor(fi, false)
      T3DSetA(fi, 0)
      layers.fill[i] = fi

      local el = T3DGroup:AddGrid('t3d-airslide-edgeL-' .. a .. '-' .. i, T3DTex)
      T3DAirSlideColor(el, true)
      T3DSetA(el, 0)
      layers.edgeL[i] = el

      local er = T3DGroup:AddGrid('t3d-airslide-edgeR-' .. a .. '-' .. i, T3DTex)
      T3DAirSlideColor(er, true)
      T3DSetA(er, 0)
      layers.edgeR[i] = er
    end
    T3DAirSlideQuads[a] = layers
  end

  for n = 1, tapPool do
    local sh = T3DGroup:AddGrid('t3d-airtap-shadow-' .. n, T3DTex)
    sh:SetColor(0, 0, 0)
    T3DSetA(sh, 0)

    local no = T3DGroup:AddGrid('t3d-airtap-' .. n, TexTap)
    T3DSetA(no, 0)

    T3DAirTapQuads[n] = { note = no, shadow = sh }
  end
end

--- 時刻 t における1拍の長さ(ms)
function T3DBeatMsAt(t)
  local bpm = 0
  pcall(function()
    local n = Chart:BpmCount()
    for i = 0, n - 1 do
      local b = Chart:BpmAt(i)
      if b ~= nil and b.time <= t then bpm = b.bpm end
    end
  end)
  if bpm == nil or bpm <= 0 then bpm = 120 end
  return 60000 / bpm
end

--- 拡張ファイルの読込結果をログに出す。level は '却下' か '警告'
local T3DAirStats = { rejected = 0, warned = 0 }
function T3DExReport(tag, level, src, msg)
  if level == '却下' then
    T3DAirStats.rejected = T3DAirStats.rejected + 1
  else
    T3DAirStats.warned = T3DAirStats.warned + 1
  end
  print(string.format('[T3D] %s %s (%s): %s', tag, level, tostring(src), msg))
end

function T3DAirReport(level, src, msg) T3DExReport('空中要素', level, src, msg) end
function T3DCamReport(level, src, msg) T3DExReport('カメラ', level, src, msg) end
function T3DMeasureReport(level, src, msg) T3DExReport('小節線', level, src, msg) end
function T3DHsReport(level, src, msg) T3DExReport('スクロール速度', level, src, msg) end
function T3DTgReport(level, src, msg) T3DExReport('TimingGroup', level, src, msg) end

--- timinggroup,グループ,時刻ms,scroll,値[,終了ms[,ease]] / timinggroup,グループ,時刻ms,jump,ms
function T3DParseTg(f, src, num)
  local usage = '書式は timinggroup,グループ,時刻ms,scroll,値[,終了ms[,ease]] か timinggroup,グループ,時刻ms,jump,ms'
  if not (num(2) and num(3) and (f[4] == 'scroll' or f[4] == 'jump') and num(5)) then
    T3DTgReport('却下', src, usage)
    return
  end
  if f[2] < 0 or f[2] ~= math.floor(f[2]) then
    T3DTgReport('却下', src, 'グループは 0 以上の整数')
    return
  end
  local r = { t = f[3], kind = f[4], v = f[5], ease = 0, src = src }
  if f[4] == 'scroll' then
    if f[6] ~= nil then
      if not num(6) or f[6] < f[3] then
        T3DTgReport('却下', src, '終了ms が数でないか、時刻より前')
        return
      end
      r.e = f[6]
    end
    if f[7] ~= nil then
      if f[7] ~= 0 and f[7] ~= 1 and f[7] ~= 2 and f[7] ~= 3 then
        T3DTgReport('却下', src, 'ease は 0〜3')
        return
      end
      r.ease = f[7]
    end
  elseif f[6] ~= nil then
    T3DTgReport('却下', src, 'jump は timinggroup,グループ,時刻ms,jump,ms')
    return
  end
  T3DTg.order = T3DTg.order + 1
  r.order = T3DTg.order
  local g = f[2]
  if T3DTg.raw[g] == nil then T3DTg.raw[g] = {} end
  table.insert(T3DTg.raw[g], r)
end

--- 縦移動を積む。dir = 'up'(床->空中判定線) / 'down'(空中判定線->床)
--- 縦移動を積む。dir = 'up'(床->空中判定線) / 'down'(空中判定線->床)。
--- 開始 == 終了 なら「直角」= その瞬間に移る継ぎ目。判定は持たず、見た目だけ
function T3DAirLift(s, e, x, dir, ease, w, src)
  local y1, y2 = 0, 255
  if dir == 'down' then y1, y2 = 255, 0 end
  table.insert(T3DAirRaw.slides, {
    kind = 'lift', s = s, e = e, x1 = x, y1 = y1, x2 = x, y2 = y2,
    ease = ease or 0, w = w or AirConf.DefaultWidth, src = src,
    instant = (e - s) < 1, g = T3DAirRaw.lineGroup,
  })
end

--- 空中判定線の上での横移動を積む
function T3DAirSlideH(s, e, x1, x2, ease, w, src)
  table.insert(T3DAirRaw.slides, {
    kind = 'slide', s = s, e = e, x1 = x1, y1 = 255, x2 = x2, y2 = 255,
    ease = ease or 0, w = w or AirConf.DefaultWidth, src = src, g = T3DAirRaw.lineGroup,
  })
end

function T3DAirTapAt(t, x, w, src)
  table.insert(T3DAirRaw.taps, { time = t, x = x, w = w or AirConf.DefaultWidth, src = src, g = T3DAirRaw.lineGroup })
end

--- 拡張ファイルを1行ずつ読んで T3DAirRaw に積む。書式の誤りはここで却下する。
--- 高さや色は書式に存在しないので、規約 A（高さは2段）と B（斜め無し）は書けない
function T3DParseAir(text, fileName)
  -- 改行文字はエスケープを書かずに組み立てる（ファイル書き出しで壊れやすいため）
  local pattern = '[^' .. string.char(13) .. string.char(10) .. ']+'
  local lineNo = 0
  for line in string.gmatch(text, pattern) do
    lineNo = lineNo + 1
    if string.sub(line, 1, 1) ~= '#' then
      local f = {}
      for v in string.gmatch(line, '[^,]+') do
        local trimmed = string.gsub(v, '%s', '')
        f[#f + 1] = tonumber(trimmed) or trimmed
      end

      local src = tostring(fileName) .. ' ' .. lineNo .. '行目'

      -- グループ指定 group=番号 は位置を問わず抜き出す（空中要素と measure だけが受け付ける）
      T3DAirRaw.lineGroup = nil
      local gBad = false
      for i = #f, 2, -1 do
        if type(f[i]) == 'string' and string.sub(f[i], 1, 6) == 'group=' then
          local gv = tonumber(string.sub(f[i], 7))
          if gv == nil or gv < 0 or gv ~= math.floor(gv) then gBad = true else T3DAirRaw.lineGroup = gv end
          table.remove(f, i)
        end
      end
      local kind = f[1]
      if gBad then
        T3DAirReport('却下', src, 'group= のあとは 0 以上の整数')
        kind = ''
      elseif T3DAirRaw.lineGroup ~= nil and kind ~= 'airtap' and kind ~= 'airslide' and kind ~= 'airlift'
          and kind ~= 'measure' and kind ~= 'trace' and kind ~= 'guide' then
        T3DAirReport('却下', src, 'group= を書けるのは airtap / airslide / airlift / measure / trace / guide だけ')
        kind = ''
      end
      local function num(i) return type(f[i]) == 'number' end
      local function inX(i) return num(i) and f[i] >= 0 and f[i] <= 255 end

      if kind == nil or kind == '' then
        -- 空行
      elseif kind == 'airlift' then
        if not (num(2) and num(3) and inX(4) and (f[5] == 'up' or f[5] == 'down')) then
          T3DAirReport('却下', src, '書式は airlift,開始ms,終了ms,x,up|down[,ease[,幅]]')
        elseif f[3] < f[2] then
          T3DAirReport('却下', src, '終了が開始より前')
        else
          -- 開始 == 終了 は「直角」。その瞬間に床 <-> 空中を移る見た目だけの継ぎ目
          T3DAirLift(f[2], f[3], f[4], f[5], f[6], f[7], src)
        end
      elseif kind == 'airslide' then
        if not (num(2) and num(3) and inX(4) and inX(5)) then
          T3DAirReport('却下', src, '書式は airslide,開始ms,終了ms,x1,x2[,ease[,幅]]（高さは指定しない）')
        elseif f[3] <= f[2] then
          T3DAirReport('却下', src, '終了が開始以前')
        else
          T3DAirSlideH(f[2], f[3], f[4], f[5], f[6], f[7], src)
        end
      elseif kind == 'measure' then
        if not (num(2) and (f[3] == nil or (num(3) and f[3] > 0))) then
          T3DMeasureReport('却下', src, '書式は measure,開始Beat[,1小節の拍数]')
        else
          MeasureStartBeat = f[2]
          if num(3) then MeasureBeats = f[3] end
          T3DVirt.measureG = T3DAirRaw.lineGroup
        end
      elseif kind == 'airtap' then
        if not (num(2) and inX(3)) then
          T3DAirReport('却下', src, '書式は airtap,時刻ms,x[,幅]（高さは指定しない）')
        else
          T3DAirTapAt(f[2], f[3], f[4], src)
        end
      elseif kind == 'hs' then
        if not (num(2) and num(3)) then
          T3DHsReport('却下', src, '書式は hs,グループ,倍率（倍率は 0.1〜10。1が既定）')
        elseif f[3] < 0.1 or f[3] > 10 then
          T3DHsReport('却下', src, '倍率が範囲外（0.1〜10）')
        else
          T3DHs[math.floor(f[2])] = f[3]
        end
      elseif kind == 'timinggroup' then
        T3DParseTg(f, src, num)
      elseif kind == 'cam' then
        local ch = f[4]
        if not (num(2) and num(3) and type(ch) == 'string' and CamRange[ch] ~= nil
            and num(5) and num(6)) then
          T3DCamReport('却下', src,
            '書式は cam,開始ms,終了ms,項目,開始値,終了値[,ease]（項目は angle/x/y/z/roll/zoom/rollpivot）')
        elseif f[3] < f[2] then
          T3DCamReport('却下', src, '終了が開始より前')
        else
          T3DAddCam(ch, f[2], f[3], f[5], f[6], f[7], src)
        end
      elseif kind == 'fx' then
        T3DParseFx(f, src)
      elseif kind == 'trace' or kind == 'guide' then
        T3DTraceAdd(kind, f, src, T3DAirRaw.lineGroup)
      else
        T3DAirReport('却下', src, '未知のキーワード ' .. tostring(kind))
      end
    end
  end
end

--- 積んだ空中要素に規約 C / D / E を当て、通ったものを描画用の表に移す
function T3DCommitAir()
  local slides, taps = T3DAirRaw.slides, T3DAirRaw.taps

  -- C: 速さと長さの目安（警告のみ）
  for _, r in ipairs(slides) do
    local beat = T3DBeatMsAt(r.s)
    local dur = r.e - r.s
    if r.instant then
      -- 直角は長さを持たないので、長さの目安は当てない
      dur = beat
    end
    if dur < beat / 8 then
      T3DAirReport('警告', r.src, string.format('1区間が 1/8 拍未満 (%dms)', dur))
    end
    if r.kind == 'lift' and dur < beat / 4 then
      T3DAirReport('警告', r.src, string.format('Lift が 1/4 拍未満 (%dms)', dur))
    end
    if r.kind == 'slide' and dur > 0 then
      local lanesPerBeat = (math.abs(r.x2 - r.x1) / (256 / T3DLanes)) / (dur / beat)
      if lanesPerBeat > 2 then
        T3DAirReport('警告', r.src, string.format('Slide が 1拍あたり %.1f レーン（目安は2まで）', lanesPerBeat))
        end
    end
  end

  -- B の継ぎ目: 時刻が接していて近くにある区間どうしなのに、位置がつながっていない区間。
  -- 別々の AirSlide がたまたま同時刻に始まる/終わることもあるので却下はしない
  for _, r in ipairs(slides) do
    local touching, matched = false, false
    for _, p in ipairs(slides) do
      if p ~= r and math.abs(p.e - r.s) <= 1 and math.abs(p.x2 - r.x1) <= r.w then
        touching = true
        if math.abs(p.x2 - r.x1) < AirConf.OverlapX and p.y2 == r.y1 then matched = true end
      end
    end
    if touching and not matched then
      T3DAirReport('警告', r.src, '直前の区間と位置がつながっていない')
    end
  end

  -- E: 画面内に同時に3本以上（時間が重なる区間の数で近似）
  for _, r in ipairs(slides) do
    local overlap = 1
    for _, p in ipairs(slides) do
      if p ~= r and p.s < r.e and r.s < p.e then overlap = overlap + 1 end
    end
    if overlap > 2 then
      T3DAirReport('警告', r.src, string.format('同時に %d 本の AirSlide が重なっている（目安は2本まで）', overlap))
    end
    table.insert(T3DAirSlides, {
      s = r.s, e = r.e, x1 = r.x1, y1 = r.y1, x2 = r.x2, y2 = r.y2, ease = r.ease, w = r.w,
      instant = r.instant, g = r.g,
    })
  end

  -- D: AirTap を AirSlide の途中に重ねない（端点と継ぎ目は可）
  for _, tap in ipairs(taps) do
    local onMiddle = nil
    for _, r in ipairs(slides) do
      if tap.time > r.s + 1 and tap.time < r.e - 1 then
        local k = T3DEase((tap.time - r.s) / (r.e - r.s), r.ease)
        local rx = r.x1 + (r.x2 - r.x1) * k
        if math.abs(rx - tap.x) < AirConf.OverlapX then
          onMiddle = r
          break
        end
      end
    end
    if onMiddle ~= nil then
      T3DAirReport('却下', tap.src, 'AirTap が AirSlide の途中に重なっている（端点か継ぎ目に置く）')
    else
      table.insert(T3DAirTaps, { time = tap.time, x = tap.x, y = 255, w = tap.w, g = tap.g })
    end
  end

  T3DBuildSkySpans()

  print(string.format('[T3D] 空中要素 読込完了: AirSlide区間=%d AirTap=%d',
    #T3DAirSlides, #T3DAirTaps))
  T3DAirRaw = { slides = {}, taps = {} }
end

--- 拡張ファイル全体の読込結果。空中要素・小節線・カメラの却下と警告をまとめて出す
function T3DExSummary()
  local hs = {}
  for g, v in pairs(T3DHs) do hs[#hs + 1] = string.format('%d=%.2f', g, v) end
  if #hs > 0 then
    table.sort(hs)
    print('[T3D] スクロール速度: ' .. table.concat(hs, ' '))
  end
  local tgs = {}
  for g, tg in pairs(T3DTg.groups) do
    tgs[#tgs + 1] = string.format('%d(%d行%s)', g, tg.lines, tg.mono and '' or ' 逆走あり')
  end
  if #tgs > 0 then
    table.sort(tgs)
    print('[T3D] TimingGroup: ' .. table.concat(tgs, ' '))
  end
  print(string.format('[T3D] 拡張ファイル 読込完了: 却下=%d 警告=%d',
    T3DAirStats.rejected, T3DAirStats.warned))
end

--- 空中判定線を点灯させる区間を作る。空中要素の時刻を並べ、
--- SkyLineConf.MergeMs より近いものはひと続きにまとめる（消えた直後にまた出るのを防ぐ）
function T3DBuildSkySpans()
  local ev = {}
  for _, r in ipairs(T3DAirSlides) do table.insert(ev, { s = r.s, e = r.e }) end
  for _, tap in ipairs(T3DAirTaps) do table.insert(ev, { s = tap.time, e = tap.time }) end
  table.sort(ev, function(a, b) return a.s < b.s end)

  T3DSkySpans = {}
  for _, r in ipairs(ev) do
    local last = T3DSkySpans[#T3DSkySpans]
    if last ~= nil and r.s - last.e <= SkyLineConf.MergeMs then
      if r.e > last.e then last.e = r.e end
    else
      table.insert(T3DSkySpans, { s = r.s, e = r.e })
    end
  end
  T3DSkyIndex = 1
end

--- 空中判定線の不透明度。普段は 0 で、空中要素が来る前に点滅してから点灯する
function T3DSkyLineAlpha(t)
  local spans = T3DSkySpans
  if spans == nil or #spans == 0 then return 0 end

  -- 時刻はほぼ単調に進むので、今見ている区間を前後に1つずつ動かすだけで足りる
  while T3DSkyIndex > 1 and t < spans[T3DSkyIndex].s - SkyLineConf.ShowMs - SkyLineConf.BlinkMs do
    T3DSkyIndex = T3DSkyIndex - 1
  end
  while T3DSkyIndex < #spans and t > spans[T3DSkyIndex].e + SkyLineConf.HideMs + SkyLineConf.FadeMs do
    T3DSkyIndex = T3DSkyIndex + 1
  end

  local sp = spans[T3DSkyIndex]
  if t >= sp.s - SkyLineConf.ShowMs and t <= sp.e + SkyLineConf.HideMs then
    return SkyLineConf.Alpha
  end

  -- 区間の後ろ。消えるときはフェードアウトする
  local tail = t - (sp.e + SkyLineConf.HideMs)
  if tail > 0 then
    if tail >= SkyLineConf.FadeMs then return 0 end
    return T3DAlpha(SkyLineConf.Alpha * (1 - tail / SkyLineConf.FadeMs))
  end

  -- 点灯の手前。点滅しながら、後ろへ行くほど明るくしてそのまま点灯につなぐ
  local lead = sp.s - SkyLineConf.ShowMs - t
  if lead > 0 and lead <= SkyLineConf.BlinkMs
      and math.floor(lead / SkyLineConf.BlinkMs1) % 2 == 0 then
    return T3DAlpha(SkyLineConf.Alpha * (1 - lead / SkyLineConf.BlinkMs))
  end
  return 0
end

--- 拡張ファイルを読む。見つからなければ false
function T3DLoadAirFile()
  for n = 1, #AirConf.FileNames do
    local ok, txt = pcall(function() return Game:ReadFile(AirConf.FileNames[n]) end)
    if ok and txt ~= nil and txt ~= '' then
      T3DParseAir(txt, AirConf.FileNames[n])
      print(string.format('[T3D] 空中要素: %s を読込', AirConf.FileNames[n]))
      return true
    end
  end
  return false
end

-- AirSlide の曲線上の点のバッファ（毎フレームテーブルを作らないよう使い回す）
local T3DAirBufX, T3DAirBufY, T3DAirBufZ = {}, {}, {}

--- AirSlide1本分の層を全部消す。前のフレームで使っていなかったスロットは何もしない
--- （空中要素の無い区間で 20本 x 14分割 x 4層 を毎フレーム消し直していたのが重さの一因だった）
function T3DHideAirSlideSlot(layers)
  if not layers.shown then return end
  layers.shown = false
  for i = 1, AirConf.SlideSamples do
    T3DSetA(layers.fill[i], 0)
    T3DSetA(layers.edgeL[i], 0)
    T3DSetA(layers.edgeR[i], 0)
    T3DSetA(layers.shadow[i], 0)
  end
end

--- AirTap 1つ分の層を消す
function T3DHideAirTapSlot(q)
  T3DSetA(q.note, 0)
  T3DSetA(q.shadow, 0)
  if q.mono ~= nil then T3DSetA(q.mono, 0) end
end

--- AirSlide 1本の、曲線上の点の奥行きを T3DAirBufZ に入れる。
--- 1点でも見える範囲（判定線〜奥の端）にかかっていれば true。
--- 譜面の scroll で止まったり戻ったりするので、時刻では見える範囲を決められない
function T3DAirSlideDepths(slide, now)
  return T3DSpanDepths(slide, now, AirConf.SlideSamples, T3DAirBufZ)
end

--- 区間 r（s, e, g を持つもの）を n 等分した点の奥行きを wz[0..n] に入れる。
--- 1点でも見える範囲（判定線〜奥の端）にかかっていれば true（AirSlide と trace / guide で共通）
function T3DSpanDepths(r, now, n, wz)
  local visible = false
  local prevZ = nil
  for i = 0, n do
    local z = T3DElemZ(r.s + (r.e - r.s) * (i / n), now, r.g)
    wz[i] = z
    if prevZ ~= nil and math.max(prevZ, z) > 0 and math.min(prevZ, z) < T3DDepth then visible = true end
    prevZ = z
  end
  return visible
end

--- AirSlide 1本を描く（奥行きは T3DAirSlideDepths で入れてあるもの）。
--- 各分割は 影（床）・板・左右の縁取り の4層
function T3DDrawAirSlide(slide, layers)
  local wx, wy, wz = T3DAirBufX, T3DAirBufY, T3DAirBufZ
  layers.shown = true

  -- 曲線上の点をワールド座標で持つ（バッファは使い回す）
  for i = 0, AirConf.SlideSamples do
    local k = T3DEase(i / AirConf.SlideSamples, slide.ease)
    wx[i] = T3DWorldX(slide.x1 + (slide.x2 - slide.x1) * k)
    wy[i] = T3DWorldY(slide.y1 + (slide.y2 - slide.y1) * k)
  end

  local ord = 700 - math.floor(math.max(math.min(wz[0], T3DDepth), 0) * 0.05)
  -- 見た目の幅 = 当たりの幅。床ノーツと同じく譜面の幅をそのまま使う
  local hw = (slide.w / 255) * T3DTrackW * 0.5
  local inner = hw - AirConf.SlideEdgeW
  -- 取り逃した区間は薄くする
  local dim = 1
  if slide.state == 'broken' then dim = BrokenConf.Dim end
  local shadowA = T3DAlpha(AirConf.SlideShadowAlpha * dim)
  local fillA = T3DAlpha(AirConf.SlideFillAlpha * dim)
  local edgeA = T3DAlpha(AirConf.SlideEdgeAlpha * dim)

  for i = 1, AirConf.SlideSamples do
    local a, b = i - 1, i
    local fill, edgeL, edgeR, shadow = layers.fill[i], layers.edgeL[i], layers.edgeR[i], layers.shadow[i]
    -- 各層の今フレームの不透明度。描けたものだけ下で値が入る（最後に1回だけ書く）
    local aS, aF, aL, aR = 0, 0, 0, 0

    -- 区間を床ノーツと同じ可視範囲 z = 0 〜 T3DDepth に切り詰める。
    -- 奥側を切らないと、床ノーツがまだ見えない時刻の部分が先に空中に現れて
    -- 床より速く流れているように見える。手前側は交点で切らないと折れて見える
    local ax, ay, az = wx[a], wy[a], wz[a]
    local bx, by, bz = wx[b], wy[b], wz[b]
    -- 逆走中は手前と奥が入れ替わることがある。帯は向きを持たないので入れ替えて扱う
    if az > bz then ax, ay, az, bx, by, bz = bx, by, bz, ax, ay, az end
    if bz > 0 and az < T3DDepth then
      if az < 0 then
        local u = (0 - az) / (bz - az)
        ax, ay, az = ax + (bx - ax) * u, ay + (by - ay) * u, 0
      end
      if bz > T3DDepth then
        local u = (T3DDepth - az) / (bz - az)
        bx, by, bz = ax + (bx - ax) * u, ay + (by - ay) * u, T3DDepth
      end

      -- 影: 床に寝かせた帯。床ノーツと完全に同じ動きをする
      if T3DSetBand(shadow, ax, az, bx, bz, hw, 0) then
        aS = shadowA
        T3DSetOrder(shadow, 16)
      end

      -- 板: 半透明の平らな面
      if T3DSetBand3(fill, ax, ay, az, bx, by, bz, hw) then
        aF = fillA
        T3DSetOrder(fill, ord)
        local c = Fx.airFill
        T3DSetTint(fill, Fx.monoStep, c[1], c[2], c[3])
      end

      -- 縁取り: 板の左右の端に沿った細い帯。面の輪郭をはっきりさせる
      local ce = Fx.airEdge
      if T3DSetBand3(edgeL, ax - inner, ay, az, bx - inner, by, bz, AirConf.SlideEdgeW) then
        aL = edgeA
        T3DSetOrder(edgeL, ord + 1)
        T3DSetTint(edgeL, Fx.monoStep, ce[1], ce[2], ce[3])
        if Fx.rgbPx > 0 then T3DRgbCopy('white', edgeA, ord + 1) end
      end
      if T3DSetBand3(edgeR, ax + inner, ay, az, bx + inner, by, bz, AirConf.SlideEdgeW) then
        aR = edgeA
        T3DSetOrder(edgeR, ord + 1)
        T3DSetTint(edgeR, Fx.monoStep, ce[1], ce[2], ce[3])
        if Fx.rgbPx > 0 then T3DRgbCopy('white', edgeA, ord + 1) end
      end
    end
    T3DSetA(shadow, aS)
    T3DSetA(fill, aF)
    T3DSetA(edgeL, aL)
    T3DSetA(edgeR, aR)
  end
end

--- AirTap 1つを奥行き dz に描く。本体はカメラ正対の板、床に影を落とす
function T3DDrawAirTap(tap, q, dz)
  local x = T3DWorldX(tap.x)
  local h = T3DWorldY(tap.y)
  local sx, sy, sc = T3DProject(x, h, dz)
  if sx == nil then
    T3DHideAirTapSlot(q)
    return
  end
  local hw = (tap.w / 255) * T3DTrackW * 0.5   -- 見た目の幅 = 当たりの幅

  -- 床に落ちる影。床ノーツと同じ速度で流れるので、見かけの遅さを打ち消す
  local nd = T3DNoteDepth * 0.35
  if T3DSetQuad(q.shadow, x - hw, x + hw, dz - nd, dz + nd, 0) then
    T3DSetA(q.shadow, AirConf.TapShadowAlpha + 10)
    T3DSetOrder(q.shadow, 16)
  end

  -- 本体
  local shw = hw * sc
  local l, r, b, top = sx - shw, sx + shw, sy - shw * 0.34, sy + shw * 0.34
  local ord = 760 - math.floor(dz * 0.1)
  T3DSetRect(q.note, l, r, b, top)
  T3DSetA(q.note, T3DAlpha(100 * T3DFxMonoKeep()))
  T3DSetOrder(q.note, ord)
  if Fx.rgbPx > 0 then
    local v = Fx.lastV
    v[1], v[2], v[3], v[4] = l, b, r, b
    v[5], v[6], v[7], v[8] = l, top, r, top
    T3DRgbCopy('tap', 100, ord)
  end
  -- モノクロ: 灰色の複製を重ねる
  if q.mono ~= nil then
    if Fx.monoV > 0 then
      T3DSetRect(q.mono, l, r, b, top)
      T3DSetA(q.mono, T3DAlpha(Fx.monoV))
      T3DSetOrder(q.mono, ord + 1)
    else
      T3DSetA(q.mono, 0)
    end
  end
end

function T3DUpdateAir(now)
  local slots, tapSlots = T3DAirSlideQuads, T3DAirTapQuads
  -- 小節線と同じ理由で、速度を実測できるまでは空中要素も出さない（仮想ノーツで位置を読むなら不要）
  if not T3DScrollMeasured and not T3DVirt.ok then
    for a = 1, #slots do T3DHideAirSlideSlot(slots[a]) end
    for n = 1, #tapSlots do
      if tapSlots[n] ~= nil then T3DHideAirTapSlot(tapSlots[n]) end
    end
    return
  end

  local usedSlide, usedTap = 0, 0
  for n = 1, #T3DAirSlides do
    local slide = T3DAirSlides[n]
    if slide.e > now - 200 and usedSlide < #slots and T3DAirSlideDepths(slide, now) then
      usedSlide = usedSlide + 1
      T3DDrawAirSlide(slide, slots[usedSlide])
    end
  end

  for n = 1, #T3DAirTaps do
    local tap = T3DAirTaps[n]
    if not tap.judged then
      local dz = T3DElemZ(tap.time, now, tap.g)
      if dz > -150 and dz < T3DDepth and usedTap < #tapSlots then
        usedTap = usedTap + 1
        T3DDrawAirTap(tap, tapSlots[usedTap], dz)
      end
    end
  end

  for a = usedSlide + 1, #slots do T3DHideAirSlideSlot(slots[a]) end
  for n = usedTap + 1, #tapSlots do T3DHideAirTapSlot(tapSlots[n]) end
end

--------------------------------------------------------------------------------
-- トレース（trace = 線 / guide = 床の帯）。判定の無い飾り
--   奥行きは空中要素と同じく仮想ノーツ（timinggroup のグループは自前の位置）から読むので、
--   譜面の scroll・停止・逆走・jump・group= にそのまま従う。
--   線は画面に向いたリボン（T3DSetHBar）。床に寝かせた帯だと、真横へ動く区間の厚みが 0 になって消える
--------------------------------------------------------------------------------
function T3DTraceReport(level, src, msg) T3DExReport('トレース', level, src, msg) end

--- 0〜3 の ease。それ以外は警告して 0
function T3DTraceEase(v, src)
  if v == nil then return 0 end
  if type(v) == 'number' and v >= 0 and v <= 3 and v == math.floor(v) then return v end
  T3DTraceReport('警告', src, 'ease は 0〜3。0 にした')
  return 0
end

--- trace / guide 行を1つ読む。f は T3DParseAir が区切った値（group= は抜いてある）
function T3DTraceAdd(kind, f, src, g)
  local function num(i) return type(f[i]) == 'number' end
  local function inX(i) return num(i) and f[i] >= 0 and f[i] <= 255 end
  if not (num(2) and num(3) and inX(4) and inX(5) and inX(6) and inX(7)) then
    if kind == 'trace' then
      T3DTraceReport('却下', src, '書式は trace,開始ms,終了ms,x1,x2,y1,y2[,ease]（x・y は 0〜255）')
    else
      T3DTraceReport('却下', src,
        '書式は guide,開始ms,終了ms,x1,x2,幅1,幅2[,ease[,不透明度]][,#rrggbb]（x・幅は 0〜255）')
    end
    return
  end
  if f[3] <= f[2] then
    T3DTraceReport('却下', src, '終了が開始以前')
    return
  end
  local r = { kind = kind, s = f[2], e = f[3], x1 = f[4], x2 = f[5], g = g, src = src }

  if kind == 'trace' then
    r.y1, r.y2 = f[6], f[7]
    r.ease = T3DTraceEase(f[8], src)
    if f[9] ~= nil then T3DTraceReport('警告', src, 'ease より後ろは書けない（線の太さは固定）。無視した') end
  else
    r.w1, r.w2 = f[6], f[7]
    r.ease = T3DTraceEase(f[8], src)
    -- 9番目以降: 数値は不透明度、#rrggbb は色（不透明度を省いて色だけ書いてもよい）
    local alphas = {}
    local c = TraceConf.GuideColor
    r.cr, r.cg, r.cb = c[1], c[2], c[3]
    for i = 9, #f do
      if num(i) then
        local a = f[i]
        if a < 0 or a > 100 then
          a = a < 0 and 0 or 100
          T3DTraceReport('警告', src, string.format('不透明度 %.1f は範囲外なので %d にした', f[i], a))
        end
        alphas[#alphas + 1] = a
      else
        local cr, cg, cb = T3DParseColor(f[i])
        if cr == nil then
          T3DTraceReport('警告', src, '色は #rrggbb で書く。既定の色にした')
        else
          r.cr, r.cg, r.cb = cr, cg, cb
        end
      end
    end
    if #alphas > 1 then T3DTraceReport('警告', src, '不透明度は1つだけ（帯の中では変えられない）。2つ目以降は無視した') end
    r.a = alphas[1] or TraceConf.GuideAlpha
  end
  table.insert(Trace.raw, r)
end

--- 読んだ行を種類ごとに時刻順へ並べる。guide の色に番号を振る（T3DSetTint の key）
function T3DCommitTrace()
  local lines, guides = {}, {}
  for _, r in ipairs(Trace.raw) do
    if r.kind == 'trace' then
      lines[#lines + 1] = r
    else
      local key = r.cr * 65536 + r.cg * 256 + r.cb
      local id = Trace.colors[key]
      if id == nil then
        Trace.colorN = Trace.colorN + 1
        id = Trace.colorN
        Trace.colors[key] = id
      end
      r.ck = id
      guides[#guides + 1] = r
    end
  end
  local function byStart(a, b) return a.s < b.s end
  table.sort(lines, byStart)
  table.sort(guides, byStart)
  Trace.lines, Trace.guides, Trace.raw = lines, guides, {}
  Trace.on = #lines > 0 or #guides > 0
  print(string.format('[T3D] トレース 読込完了: trace=%d guide=%d', #lines, #guides))
end

--- 描画用の Grid を作る。行のある種類だけ（見えない Grid も毎フレームの描画に効く）
function T3DBuildTrace()
  local n = TraceConf.Samples
  local lc, sc = TraceConf.LineColor, TraceConf.ShadowColor
  local linePool = (#Trace.lines > 0) and TraceConf.LinePool or 0
  local guidePool = (#Trace.guides > 0) and TraceConf.GuidePool or 0
  for a = 1, linePool do
    local slot = { body = {}, shadow = {}, shown = false }
    slot.dot = T3DGroup:AddGrid('t3d-trace-dot-' .. a, TraceConf.DotTex)
    T3DSetA(slot.dot, 0)
    for i = 1, n do
      local sh = T3DGroup:AddGrid('t3d-trace-shadow-' .. a .. '-' .. i, T3DTex)
      sh:SetColor(sc[1], sc[2], sc[3])
      T3DSetA(sh, 0)
      slot.shadow[i] = sh
      local q = T3DGroup:AddGrid('t3d-trace-' .. a .. '-' .. i, T3DTex)
      q:SetColor(lc[1], lc[2], lc[3])
      T3DSetA(q, 0)
      slot.body[i] = q
    end
    Trace.linePool[a] = slot
  end
  for a = 1, guidePool do
    local slot = { q = {}, shown = false }
    for i = 1, n do
      local q = T3DGroup:AddGrid('t3d-guide-' .. a .. '-' .. i, T3DTex)
      T3DSetA(q, 0)
      slot.q[i] = q
    end
    Trace.guidePool[a] = slot
  end
end

--- 奥行き za -> zb の線分のうち、見える範囲（0 〜 T3DDepth）にかかる部分を u（0〜1）で返す。かからなければ nil
function T3DClipU(za, zb)
  if za == zb then
    if za > 0 and za < T3DDepth then return 0, 1 end
    return nil
  end
  local ua, ub = (0 - za) / (zb - za), (T3DDepth - za) / (zb - za)
  if ua > ub then ua, ub = ub, ua end
  if ua < 0 then ua = 0 end
  if ub > 1 then ub = 1 end
  if ua >= ub then return nil end
  return ua, ub
end

--- トレース1区間の点の奥行きを wz[0..n] に入れる。見える範囲にかかれば true。
--- 仮想ノーツは両端にしか置かないので、途中の点は両端から時刻に比例して埋める（区間の中の scroll は一定とみなす）。
--- 片方の端がまだ出ていない / 通り過ぎたときは、読めた端から今の scroll の速さで延ばす。
--- timinggroup のグループと、仮想ノーツを使わないとき（時刻から出す）は、全部の点を T3DElemZ で求める
function T3DTraceDepths(r, now, n, wz)
  if T3DTgOf(r.g) ~= nil or not T3DVirt.ok then return T3DSpanDepths(r, now, n, wz) end
  local far = T3DFarZ * 0.5
  local z0, z1 = T3DElemZ(r.s, now, r.g), T3DElemZ(r.e, now, r.g)
  local ok0, ok1 = z0 > -far and z0 < far, z1 > -far and z1 < far
  local len = r.e - r.s
  -- 奥行き / ms（今の scroll）。まだ測れていなければ scroll 1 とみなす
  local slope = T3DVirt.rate * T3DDepth * T3DSpeed * T3DHsOf(r.g)
  if slope == 0 then slope = T3DDepth / T3DLeadMs() * T3DHsOf(r.g) end
  if ok0 and not ok1 then
    z1 = z0 + len * slope
  elseif ok1 and not ok0 then
    z0 = z1 - len * slope
  elseif not ok0 and not ok1 then
    z0 = (r.s - now) * slope
    z1 = z0 + len * slope
  end
  local visible = false
  local prevZ = nil
  for i = 0, n do
    local z = z0 + (z1 - z0) * (i / n)
    wz[i] = z
    if prevZ ~= nil and math.max(prevZ, z) > 0 and math.min(prevZ, z) < T3DDepth then visible = true end
    prevZ = z
  end
  return visible
end

--- 1区間を1枚にまとめて描けるなら、まとめる点の範囲 lo, hi を返す（まとめられなければ nil）。
--- ease 0 で区間の中の scroll が一定なら 3D 空間でまっすぐなので、分割 8 枚ぶんの SetVertex を省ける。
--- まだ出ていない点（T3DFarZ）・通り過ぎた点（-T3DFarZ）は除き、残りの点が奥行きでまっすぐ並んでいて、
--- 除いた側が見える範囲の外（手前は判定線より手前、奥は奥の端より奥）にあるときだけまとめる。
--- 区間の中で scroll が変わる（停止・逆走・jump）と奥行きが時刻に比例しないので分割する
function T3DTraceSpan(r, n, wz)
  if r.ease ~= 0 then return nil end
  local far = T3DFarZ * 0.5
  local lo, hi = 0, n
  while lo <= n and wz[lo] <= -far do lo = lo + 1 end
  while hi >= 0 and wz[hi] >= far do hi = hi - 1 end
  if hi - lo < 1 then return nil end
  if (lo > 0 and wz[lo] > 0) or (hi < n and wz[hi] < T3DDepth) then return nil end
  local z0, dz = wz[lo], (wz[hi] - wz[lo]) / (hi - lo)
  for i = lo + 1, hi - 1 do
    if math.abs(wz[i] - (z0 + dz * (i - lo))) > 1 then return nil end
  end
  return lo, hi
end

function T3DHideTraceSlot(slot)
  if not slot.shown then return end
  slot.shown = false
  T3DSetA(slot.dot, 0)
  for i = 1, TraceConf.Samples do
    T3DSetA(slot.body[i], 0)
    T3DSetA(slot.shadow[i], 0)
  end
end

function T3DHideGuideSlot(slot)
  if not slot.shown then return end
  slot.shown = false
  for i = 1, TraceConf.Samples do T3DSetA(slot.q[i], 0) end
end

--- 区間の点 [0..n] のワールド x と、y（trace は高さ・guide は半幅）を Trace.bufX / bufY に入れる
function T3DTracePoints(r, n)
  local wx, wy = Trace.bufX, Trace.bufY
  for i = 0, n do
    local k = T3DEase(i / n, r.ease)
    wx[i] = T3DWorldX(r.x1 + (r.x2 - r.x1) * k)
    if r.kind == 'trace' then
      wy[i] = T3DWorldY(r.y1 + (r.y2 - r.y1) * k)
    else
      wy[i] = ((r.w1 + (r.w2 - r.w1) * k) / 255) * T3DTrackW * 0.5
    end
  end
end

--- trace 1区間を描く（奥行きは Trace.bufZ に入れてある）
function T3DDrawTrace(r, slot)
  local n = TraceConf.Samples
  local wx, wy, wz = Trace.bufX, Trace.bufY, Trace.bufZ
  slot.shown = true
  T3DTracePoints(r, n)
  local hw = TraceConf.LineHalf
  local minS = TraceConf.LineMinPx / hw   -- 画面上の太さの下限を、遠近の縮尺の下限として渡す
  local dotX, dotY = nil, nil
  local ord = TraceConf.LineOrder - math.floor(math.max(math.min(wz[0], T3DDepth), 0) * 0.05)
  local lineA = T3DAlpha(TraceConf.LineAlpha)
  local mlo, mhi = T3DTraceSpan(r, n, wz)
  for i = 1, n do
    local a, b = i - 1, i
    if mlo ~= nil then
      if i == 1 then a, b = mlo, mhi else a = nil end
    end
    local q, sh = slot.body[i], slot.shadow[i]
    local aB, aS = 0, 0
    local u0, u1 = nil, nil
    if a ~= nil then u0, u1 = T3DClipU(wz[a], wz[b]) end
    if u0 ~= nil then
      local dx, dy, dz = wx[b] - wx[a], wy[b] - wy[a], wz[b] - wz[a]
      -- 判定線（奥行き 0）をまたぐ分割なら、またぐ点に光の点を出す
      if dotX == nil and (wz[a] <= 0) ~= (wz[b] <= 0) then
        local u = -wz[a] / dz
        dotX, dotY = wx[a] + dx * u, wy[a] + dy * u
      end
      local ax, ay, az = wx[a] + dx * u0, wy[a] + dy * u0, wz[a] + dz * u0
      local bx, by, bz = wx[a] + dx * u1, wy[a] + dy * u1, wz[a] + dz * u1
      local sx0, sy0, s0 = T3DProject(ax, ay, az)
      local sx1, sy1, s1 = T3DProject(bx, by, bz)
      if sx0 ~= nil and sx1 ~= nil
          and T3DSetHBar(q, sx0, sy0, math.max(s0, minS), sx1, sy1, math.max(s1, minS), hw) then
        aB = lineA
        T3DSetOrder(q, ord)
        if Fx.rgbPx > 0 then T3DRgbCopy('white', lineA, ord) end
      end
      -- 影: 空中にある部分だけ、真下の床に同じ形で落とす
      if ay > 0 or by > 0 then
        sx0, sy0, s0 = T3DProject(ax, 0, az)
        sx1, sy1, s1 = T3DProject(bx, 0, bz)
        if sx0 ~= nil and sx1 ~= nil
            and T3DSetHBar(sh, sx0, sy0, math.max(s0, minS), sx1, sy1, math.max(s1, minS), hw) then
          aS = TraceConf.ShadowAlpha
          T3DSetOrder(sh, 16)
        end
      end
    end
    T3DSetA(q, aB)
    T3DSetA(sh, aS)
  end
  local aD = 0
  if dotX ~= nil then
    local sx, sy, sc = T3DProject(dotX, dotY, 0)
    if sx ~= nil and T3DSetBillboard(slot.dot, sx, sy, TraceConf.DotHalf * sc) then
      aD = TraceConf.DotAlpha
      T3DSetOrder(slot.dot, TraceConf.DotOrder)
    end
  end
  T3DSetA(slot.dot, aD)
end

--- guide 1区間を描く。不透明度は帯の中で一定
function T3DDrawGuide(r, slot)
  local n = TraceConf.Samples
  local wx, wh, wz = Trace.bufX, Trace.bufY, Trace.bufZ
  slot.shown = true
  T3DTracePoints(r, n)
  -- 色: モノクロ演出の段階が変わったときだけ灰色へ寄せた色を作り直す
  local step = Fx.monoStep
  if r.monoK ~= step then
    r.monoK = step
    r.tint = (step > 0) and T3DFxGray(r.cr, r.cg, r.cb, step) or nil
  end
  local key = r.ck * 100 + math.floor(step * 10 + 0.5)
  local cr, cg, cb = r.cr, r.cg, r.cb
  if r.tint ~= nil then cr, cg, cb = r.tint[1], r.tint[2], r.tint[3] end
  local mlo, mhi = T3DTraceSpan(r, n, wz)
  for i = 1, n do
    local a, b = i - 1, i
    if mlo ~= nil then
      if i == 1 then a, b = mlo, mhi else a = nil end
    end
    local q = slot.q[i]
    local aq = 0
    local u0, u1 = nil, nil
    if a ~= nil then u0, u1 = T3DClipU(wz[a], wz[b]) end
    if u0 ~= nil then
      local dx, dh, dz = wx[b] - wx[a], wh[b] - wh[a], wz[b] - wz[a]
      local ax, ah, az = wx[a] + dx * u0, wh[a] + dh * u0, wz[a] + dz * u0
      local bx, bh, bz = wx[a] + dx * u1, wh[a] + dh * u1, wz[a] + dz * u1
      -- 手前を先に（逆走中は入れ替わる）
      if az > bz then ax, ah, az, bx, bh, bz = bx, bh, bz, ax, ah, az end
      if T3DSetBand(q, ax, az, bx, bz, ah, 0, bh) then
        aq = T3DAlpha(r.a)
        T3DSetOrder(q, TraceConf.GuideOrder)
        T3DSetTint(q, key, cr, cg, cb)
      end
    end
    T3DSetA(q, aq)
  end
end

function T3DUpdateTrace(now)
  local lp, gp = Trace.linePool, Trace.guidePool
  -- 空中要素と同じく、位置を読めるようになるまでは出さない
  if not T3DScrollMeasured and not T3DVirt.ok then
    for a = 1, #lp do T3DHideTraceSlot(lp[a]) end
    for a = 1, #gp do T3DHideGuideSlot(gp[a]) end
    return
  end
  local n, wz = TraceConf.Samples, Trace.bufZ
  local usedL, usedG = 0, 0
  local over = false
  local lines, guides = Trace.lines, Trace.guides
  -- 区間は開始時刻の順。先頭の通り過ぎた区間は次から見ない（リトライ等で時刻が戻ったら最初から）。
  -- 開始が遠い未来（窓の2倍 = scroll 10倍でも見えない先）の区間からは後ろを見ない
  if now < Trace.lastNow then Trace.lineFirst, Trace.guideFirst = 1, 1 end
  Trace.lastNow = now
  local past, ahead = now - 200, now + math.max(T3DScrollWindow * 2, 4000)
  while Trace.lineFirst <= #lines and lines[Trace.lineFirst].e < past do Trace.lineFirst = Trace.lineFirst + 1 end
  while Trace.guideFirst <= #guides and guides[Trace.guideFirst].e < past do Trace.guideFirst = Trace.guideFirst + 1 end
  for k = Trace.lineFirst, #lines do
    local r = lines[k]
    if r.s > ahead then break end
    if r.e > past and T3DTraceDepths(r, now, n, wz) then
      if usedL < #lp then
        usedL = usedL + 1
        T3DDrawTrace(r, lp[usedL])
      else
        over = true
      end
    end
  end
  for k = Trace.guideFirst, #guides do
    local r = guides[k]
    if r.s > ahead then break end
    if r.e > past and T3DTraceDepths(r, now, n, wz) then
      if usedG < #gp then
        usedG = usedG + 1
        T3DDrawGuide(r, gp[usedG])
      else
        over = true
      end
    end
  end
  for a = usedL + 1, #lp do T3DHideTraceSlot(lp[a]) end
  for a = usedG + 1, #gp do T3DHideGuideSlot(gp[a]) end
  if over and not Trace.overLogged then
    Trace.overLogged = true
    print(string.format('[T3D] トレース: 同時に描ける数（trace %d / guide %d 区間）を超えた分は描いていない',
      TraceConf.LinePool, TraceConf.GuidePool))
  end
end

--------------------------------------------------------------------------------
-- カスタム設定の読込
--------------------------------------------------------------------------------
local function T3DGetNumber(key)
  local ok, v = pcall(function() return Module:GetNumber(key) end)
  if ok and type(v) == 'number' then return v end
  return 0
end

local function T3DGetBool(key)
  local ok, v = pcall(function() return Module:GetBool(key) end)
  return ok and v == true
end

local function T3DClamp(v, range)
  if v < range[1] then return range[1] end
  if v > range[2] then return range[2] end
  return v
end

-- 設定で消せる演出。T3DBuilt は Init で作れたか、T3DHide は設定で消されているか。
-- 実際に使う T3D.xxx は「作れた かつ 消されていない」（T3DApplyFxSettings）。
-- 設定で消されていても素材は Init で必ず作っておく。そうしないとリトライで表示に戻せない
local T3DFxKeys = { 'HitFx', 'HoldFx', 'JudgeText', 'Measure' }
local T3DBuilt = {}
-- T3DHide は画面演出の節でも読むので、そちらより前（画面の変形の節）で宣言している

--- 設定を読む。リトライのたびにも呼ぶので、毎回既定値から決め直す
function T3DLoadSettings()
  UserZoom = 1
  local scale = T3DGetNumber(SettingKeys.LaneScale)
  if scale > 0 then UserZoom = T3DClamp(scale, LaneScaleRange) / 100 end

  T3DTrackAngle = T3DTrackAngleBase
  local angle = T3DGetNumber(SettingKeys.LaneAngle)
  if angle > 0 then T3DTrackAngle = T3DClamp(angle, LaneAngleRange) end

  T3DHide.HitFx     = T3DGetBool(SettingKeys.HideHitFx)
  T3DHide.HoldFx    = T3DGetBool(SettingKeys.HideHoldFx)
  T3DHide.JudgeText = T3DGetBool(SettingKeys.HideJudge)
  T3DHide.Measure   = T3DGetBool(SettingKeys.HideBar)
  T3DHide.AutoFx    = T3DGetBool(SettingKeys.HideAutoFx)
  T3DHide.ChartFx   = T3DGetBool(SettingKeys.HideChartFx)
  local function shown(k) return T3DHide[k] and '非表示' or '表示' end

  print(string.format('[T3D]   設定: 拡大率=%.0f%%(読んだ値 %s) 傾き=%.1f(読んだ値 %s) TapEffect=%s HoldEffect=%s 判定表示=%s 小節線=%s'
    .. ' 自動演出=%s 譜面演出=%s',
    UserZoom * 100, tostring(scale), T3DTrackAngle, tostring(angle),
    shown('HitFx'), shown('HoldFx'), shown('JudgeText'), shown('Measure'),
    shown('AutoFx'), shown('ChartFx')))
end

--- 設定で消された演出を止める。止めたものは表示中の分も消す
function T3DApplyFxSettings()
  for _, k in ipairs(T3DFxKeys) do
    T3D[k] = (T3DBuilt[k] == true) and not T3DHide[k]
  end
  if not T3D.Measure then
    for i = 1, #T3DMeasureQuads do T3DSetA(T3DMeasureQuads[i], 0) end
  end
end

-- Cam のうち、譜面の cam 行で動く項目の初期値。リトライで傾きを組み直す前に戻す
local T3DCamStart = { X = Cam.X, Y = Cam.Y, Z = Cam.Z, Roll = Cam.Roll }

--- 傾きと拡大率からカメラを組む（Init とリトライで共通）
function T3DSetupTrackAngle()
  local angle = T3DTrackAngle
  local ok, v = pcall(function() return Game:FieldMeta('Angle') end)
  if UseFieldAngle and ok and type(v) == 'number' and v >= 10 and v <= 80 then
    angle = v
  end
  T3DApplyTrackAngle(angle, UserZoom)
  T3DTrackAngleUsed = angle   -- cam の angle を書かなかったときの既定値になる
  -- 譜面の cam 行が angle / rollpivot を書いていない間の既定値
  CamBase.angle = T3DTrackAngleUsed
  CamBase.rollpivot = T3DRollPivotY
  print(string.format(
    '[T3D]   トラック角度=%.1f -> Pitch=%.1f / 床手前端z=%.0f / 空中判定線の高さ=%.0f',
    angle, Cam.Pitch, T3DFloorNear, T3DHeightMax))
end

--- リトライ時に設定を読み直して反映する（プレイ中に設定画面で変えた値がここで効く）
function T3DReloadSettings()
  T3DLoadSettings()
  Cam.X, Cam.Y, Cam.Z, Cam.Roll = T3DCamStart.X, T3DCamStart.Y, T3DCamStart.Z, T3DCamStart.Roll
  T3DSetupTrackAngle()
  T3DApplyFxSettings()
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------
function Init()
  print('[T3D] Init begin')
  if T3D.PerfLog then Step('計測', T3DPerfInit) end
  -- 拡大率と傾きはカメラを組む前に読む
  Step('カスタム設定', T3DLoadSettings)

  Step('Game:Width/Height', function()
    GameWidth  = Game:Width()
    GameHeight = Game:Height()
  end)

  Step('Track angle', T3DSetupTrackAngle)

  Step('Note:GetGroup', function()
    T3DGroup = Note:GetGroup('t3d-lane')
    T3DGroup.Alpha = 100
  end)
  if T3DGroup == nil then
    print('[T3D] Init abort: 描画用のグループが取れない')
    return
  end

  if T3D.Floor then
    if not Step('BuildFloor', T3DBuildFloor) then T3D.Floor = false end
  end
  -- ここの3つと小節線は設定で消されていても作る。表示するかは最後に T3DApplyFxSettings で決める
  if T3D.HitFx then T3DBuilt.HitFx = Step('BuildHitFx', T3DBuildHitFx) end
  if T3D.JudgeText then T3DBuilt.JudgeText = Step('BuildJudgeText', T3DBuildJudgeText) end
  if T3D.HoldFx then T3DBuilt.HoldFx = Step('BuildHoldFx', T3DBuildHoldFx) end
  -- 拡張ファイル。空中要素・小節線・カメラ演出が全部ここから来るので、
  -- どれか1つを切ってあっても読込自体は行う
  Step('LoadEx', T3DLoadAirFile)
  Step('TimingGroup', T3DCommitTg)
  -- LegacyMode (Beta)。途中で切り替えると、描いた後のノーツと新しいノーツで描き方が混ざるので、
  -- リトライでは読み直さず、曲を開いたときだけ決める
  Step('LegacySlide', function()
    T3D.LegacySlide = T3DGetBool(SettingKeys.LegacyMode)
    if T3D.LegacySlide then T3DLoadLegacy() else print('[T3D] LegacySlide: OFF') end
  end)

  if T3D.Air then
    if not Step('BuildAir', function()
      T3DCommitAir()
      T3DBuildAir()
    end) then T3D.Air = false end
  end
  if T3D.Trace then
    if not Step('BuildTrace', function()
      T3DCommitTrace()
      T3DBuildTrace()
    end) then T3D.Trace = false end
  end

  if T3D.Cam then
    if not Step('BuildCam', T3DCommitCam) then T3D.Cam = false end
  end

  if T3D.Fx then
    if not Step('BuildFx', function()
      T3DCommitFx()
      T3DBuildFx()
    end) then T3D.Fx = false end
  end

  if T3D.Measure then
    T3DBuilt.Measure = Step('BuildMeasure', function()
      T3DBuildBpmTable()
      T3DBuildMeasure()
    end)
  end
  T3DApplyFxSettings()

  Step('拡張ファイルの集計', T3DExSummary)

  Step('判定レベル', T3DApplyJudgeLevel)

  -- 判定は自前だが、エンジン側の自動 Miss も保険として残す。
  -- フリックは押してから方向入力を待つので、その待ち時間より後に来るようにする
  Step('Play:SetMissTime', function()
    Play:SetMissTime(JudgeWindow.Good + FlickConf.TimeoutMs + 50)
  end)

  Step('Auto', function()
    T3DAuto = (Play:IsAuto() == true)
    print('[T3D]   Auto=' .. tostring(T3DAuto))
  end)

  -- HP ゲージを満タンから始める（スコア・コンボ・精度もここで初期値を入れる）
  Step('初期スコア', T3DPushScore)

  T3DAlive = true
  print('[T3D] Init end')
end

--------------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------------
function Update()
  if not T3DAlive then return end
  local t = Game:Time()
  local perf = T3DPerf
  local perfT0 = nil
  if perf ~= nil then
    T3DPerfFrame(t)
    if T3DClock then perfT0 = T3DClock() end
  end
  T3DTgFrame(t)
  T3DUpdateBody(t)
  if perfT0 ~= nil then
    local d = (T3DClock() - perfT0) * 1000
    perf.updSum = perf.updSum + d
    if d > perf.updMax then perf.updMax = d end
  end
end

function T3DUpdateBody(t)

  -- カメラ演出は描画より先。ここで動かした Cam に全要素が追従する
  if T3D.Cam        then T3DSafe('Cam',        T3DUpdateCam, t) end
  -- 画面の変形もここで決める（床・ノーツ・空中要素の頂点に掛かる）
  if T3D.Fx         then T3DSafe('Fx',         T3DUpdateFx, t) end

  -- 描画
  if T3D.Floor      then T3DSafe('Floor',      T3DUpdateFloor, t) end
  if T3D.Measure    then T3DSafe('Measure',    T3DUpdateMeasure, t) end
  if T3D.HitFx      then T3DSafe('HitFx',      T3DUpdateHitFx, t) end
  if T3D.JudgeText  then T3DSafe('JudgeText',  T3DUpdateJudgeText, t) end
  if T3D.HoldFx     then T3DSafe('HoldFx',     T3DUpdateHoldFx, t) end
  if T3D.Air        then T3DSafe('Air',        T3DUpdateAir, t) end
  if T3D.Trace and Trace.on then T3DSafe('Trace', T3DUpdateTrace, t) end

  -- 判定: 自動処理 -> 重なりで取るもの(Wipe・Hold/Slide の開始) -> フリックの時間切れ -> Hold 継続 -> 空中 -> 見逃し Miss
  if T3D.Judge then
    if T3DAuto then T3DSafe('Auto', T3DUpdateAuto, t) end
    T3DSafe('Touch',    T3DUpdateTouchNotes, t)
    T3DSafe('Flicks',   T3DUpdateFlicks)
    T3DSafe('Holds',    T3DUpdateHolds, t)
    if T3D.Air then T3DSafe('AirJudge', T3DUpdateAirJudge, t) end
    T3DSafe('AutoMiss', T3DAutoMiss, t)
  end
end


--------------------------------------------------------------------------------
-- ノーツのコンテナと中継点（床ノーツの描画と判定の両方で使う）
--------------------------------------------------------------------------------

--- ノーツのコンテナの子。GetChild は C# 側を呼ぶうえ 'seg'..i の文字列も作るので、
--- 1つのノーツが流れている間は1回だけ引いて覚えておく。帯は**描くときに初めて引く**
--- （中継点が数百ある Slide で、出てきた瞬間に全部を引くと1フレームに呼び出しが集中する）。
--- コンテナが別のノーツに使い回されたら、前のノーツで見えていた帯だけを消してから引き直し、
--- 覚えている Alpha / Order / 色も捨てる。
--- コンテナの数はエンジンのプール分しか無いので、弱参照にはしない
--- （忘れると「前のノーツで見えていた帯」が分からなくなる）
local T3DNoteKids = {}

function T3DKidsOf(mod, info, segCount)
  local slots = T3DBandSlots(segCount)
  local old = T3DNoteKids[mod]
  if old ~= nil and old.nid == info.nid and old.slots == slots then return old end
  if old ~= nil then T3DHideNoteChildren(old) end

  -- used は「前のフレームで使った帯の Grid の数」（1〜used 番が使用中）
  local k = { slots = slots, nid = info.nid, mod = mod, seg = {}, used = 0 }
  k.head = mod:GetChild('head')
  if T3D.Flick and (info.type == 5 or info.type == 6) then k.arrow = mod:GetChild('arrow') end
  if k.head ~= nil then T3DQState[k.head] = nil end
  if k.arrow ~= nil then T3DQState[k.arrow] = nil end
  T3DNoteKids[mod] = k
  if T3DPerf ~= nil then T3DPerf.kidBuilds = T3DPerf.kidBuilds + 1 end
  return k
end

--- 帯の Grid の i 番。初めて使うときに GetChild する（無ければ nil）
function T3DBandOf(k, i)
  local b = k.seg[i]
  if b == nil then
    b = k.mod:GetChild('seg' .. i) or false
    k.seg[i] = b
    if b then T3DQState[b] = nil end
  end
  return b or nil
end

--- ノーツのコンテナの子を全部消す。奥すぎるとき / 帯を通過し終わったときに使う
function T3DHideNoteChildren(k)
  if k.head ~= nil then T3DSetA(k.head, 0) end
  if k.arrow ~= nil then T3DSetA(k.arrow, 0) end
  -- 帯は使っていた Grid だけ消せば足りる（中継点が数百ある Slide で全部を回さない）
  T3DReleaseBands(k, 0)
end

--- 帯の Grid のうち、used+1 番から前のフレームで使っていた番までを消し、使用数を used にする
function T3DReleaseBands(k, used)
  for i = used + 1, k.used do
    local b = k.seg[i]
    if b then T3DSetA(b, 0) end
  end
  k.used = used
end

--- ノーツの segment を Lua の配列に写したもの。nid -> { n, t = {}, x = {}, ... }。
--- t[i] / x[i] は i=0 が頭、i=1〜n が各 segment の**絶対**時刻と譜面x。
--- info.segments[i].x のような読み出しは1回ごとに C# 側を呼ぶので、中継点が数百ある Slide
--- （例: 4秒で352点のギザギザ）を毎フレーム頭から読むと、それだけで千回単位の呼び出しになる。
--- segment は譜面のデータで変わらないので、**必要になった点だけ**を1回ずつ写す
--- （出てきた瞬間に全部写すと、そのフレームに呼び出しが集中する）
local T3DSegCache = {}

--------------------------------------------------------------------------------
-- LegacyMode (Beta)（Issue #3）
--   旧 Malody では、中継点の時刻が前の点より戻ると、その辺は描かず次の点から別の本体として描く（敷スライド）。
--   分かれた後の本体には判定が無く、判定は最初の区間（頭〜最初に戻る点）だけ。
--   帯は「終わりの点の時刻を過ぎたら消える」。始まりの時刻が来た帯は判定線で切り、まだの帯は判定線より手前でも描く。
--   エンジンは中継点を時刻順に並べ替えて渡すので、元の順は譜面ファイル（.mc）を読んで取る。
--   今の譜面のファイル名は公式 API では取れないため、Chart の中にある譜面DBのレコード
--   （Malody.DB.ChartRecord。型名は難読化されていない）の Path をリフレクションで読む。
--   取れなければ LegacyMode は効かない（従来の描き方のまま）
--------------------------------------------------------------------------------
local T3DLegacy = { count = 0, odd = 0, byT = {}, NearZ = -600, bufZ = {}, cand = {},
  pos = nil, W = nil, posBad = false }

--- 今の譜面ファイルのフルパス。Chart 自身か、その子（1段目）のうち Malody.* の型の中に
--- Malody.DB.ChartRecord のフィールドがあれば Path を読む。取れなければ nil
function T3DLegacyChartPath()
  local function getType(s) return CS.System.Type.GetType(s) end
  local typeType = getType('System.Type, mscorlib')
  local strType  = getType('System.String, mscorlib')
  local objType  = getType('System.Object, mscorlib')
  local function typeArrL(l) local a = CS.System.Array.CreateInstance(typeType, #l) for i, t in ipairs(l) do a:SetValue(t, i - 1) end return a end
  local function objArrL(l) local a = CS.System.Array.CreateInstance(objType, #l) for i, v in ipairs(l) do a:SetValue(v, i - 1) end return a end
  local bfType = getType('System.Reflection.BindingFlags, mscorlib')
  local parseM = getType('System.Enum, mscorlib'):GetMethod('Parse', typeArrL({ typeType, strType }))
  local bf = parseM:Invoke(nil, 0, nil, objArrL({ bfType, 'Public, NonPublic, Instance, Static' }), nil)

  local function isStatic(f) local s = false pcall(function() s = f.IsStatic end) return s end
  local function recordIn(obj)
    local fs = obj:GetType():GetFields(bf)
    for i = 0, fs.Length - 1 do
      local f = fs[i]
      if not isStatic(f) and tostring(f.FieldType.FullName) == 'Malody.DB.ChartRecord' then
        local rec = nil
        pcall(function() rec = f:GetValue(obj) end)
        if rec ~= nil then return rec end
      end
    end
    return nil
  end
  local rec = recordIn(Chart)
  if rec == nil then
    local fs = Chart:GetType():GetFields(bf)
    for i = 0, fs.Length - 1 do
      local f = fs[i]
      if not isStatic(f) and string.sub(tostring(f.FieldType.FullName), 1, 7) == 'Malody.' then
        local v = nil
        pcall(function() v = f:GetValue(Chart) end)
        if v ~= nil then
          pcall(function() rec = recordIn(v) end)
          if rec ~= nil then break end
        end
      end
    end
  end
  if rec == nil then return nil end
  local path = nil
  pcall(function() path = rec:GetType():GetProperty('Path'):GetValue(rec, nil) end)
  if path == nil then pcall(function() path = rec:GetType():GetField('path_', bf):GetValue(rec) end) end
  if path == nil then return nil end
  return tostring(path)
end

--- 最小限の JSON 読み取り（.mc 用）。\u のエスケープは '?' にする（譜面の数値には出てこない）
function T3DJsonDecode(s)
  local find, sub, byte = string.find, string.sub, string.byte
  local pos = 1
  local esc = { n = '\n', t = '\t', r = '\r', b = '\b', f = '\f' }
  local function ws() pos = find(s, '[^ \t\r\n]', pos) or (#s + 1) end
  local function str()
    local out, i = {}, pos + 1
    while true do
      local j = find(s, '["\\]', i)
      if j == nil then error('json: 文字列が閉じていない') end
      out[#out + 1] = sub(s, i, j - 1)
      if byte(s, j) == 34 then pos = j + 1 break end
      local c = sub(s, j + 1, j + 1)
      if c == 'u' then out[#out + 1] = '?' i = j + 6 else out[#out + 1] = esc[c] or c i = j + 2 end
    end
    return table.concat(out)
  end
  local val
  val = function()
    ws()
    local c = byte(s, pos)
    if c == 123 then                                  -- {
      pos = pos + 1
      local o = {}
      ws()
      if byte(s, pos) == 125 then pos = pos + 1 return o end
      while true do
        ws()
        local k = str()
        ws()
        pos = pos + 1                                 -- :
        o[k] = val()
        ws()
        local d = byte(s, pos)
        pos = pos + 1
        if d == 125 then return o end
      end
    elseif c == 91 then                               -- [
      pos = pos + 1
      local a = {}
      ws()
      if byte(s, pos) == 93 then pos = pos + 1 return a end
      while true do
        a[#a + 1] = val()
        ws()
        local d = byte(s, pos)
        pos = pos + 1
        if d == 93 then return a end
      end
    elseif c == 34 then return str()
    elseif c == 116 then pos = pos + 4 return true
    elseif c == 102 then pos = pos + 5 return false
    elseif c == 110 then pos = pos + 4 return nil
    end
    local a, b = find(s, '^-?[%d%.eE%+%-]+', pos)
    if a == nil then error('json: 値が読めない位置 ' .. pos) end
    pos = b + 1
    return tonumber(sub(s, a, b))
  end
  return val()
end

--- .mc の中身から Slide をすべて T3DLegacy に登録する。
--- 時刻が戻らない Slide も、旧版の「帯は終わりの点の時刻で消える」描き方（逆走や jump で帯が途切れる・点滅して見える演出）にするため。
--- 同じ ms に丸められた点の並びも元の順で持てる。T3DLegacy.odd は時刻が戻る点・負の時刻の点を持つもの（敷）の数
function T3DLegacyFromMc(txt)
  if string.sub(txt, 1, 3) == '\239\187\191' then txt = string.sub(txt, 4) end
  local d = T3DJsonDecode(txt)
  local function bt(b)
    if b == nil then return 0 end
    local den = b[3]
    if den == nil or den == 0 then return b[1] or 0 end
    return b[1] + b[2] / den
  end
  local tl = {}
  for _, t in ipairs(d.time or {}) do
    if t.bpm ~= nil and t.bpm > 0 then tl[#tl + 1] = { b = bt(t.beat), bpm = t.bpm } end
  end
  if #tl == 0 then return end
  table.sort(tl, function(p, q) return p.b < q.b end)
  local function ms(beat)
    local t, pb, pbpm = 0, tl[1].b, tl[1].bpm
    for i = 2, #tl do
      if beat <= tl[i].b then break end
      t = t + (tl[i].b - pb) * 60000 / pbpm
      pb, pbpm = tl[i].b, tl[i].bpm
    end
    return t + (beat - pb) * 60000 / pbpm
  end
  -- 位置の曲線（エンジンの p と同じ式）。描画のたびに C# 側の p を読まずに済むようにする。
  -- 同じ行に jump と scroll があるときは、jump に変わる前の scroll を掛ける（MalodyV の挙動に合わせた推定。
  -- 描画のときにエンジンの p と照らし合わせ、ずれていたら p を読む描き方に戻る）。hs があれば使わない
  local fx, unsafe = {}, false
  for i, e in ipairs(d.effect or {}) do
    local t = ms(bt(e.beat))
    if e.hs ~= nil then unsafe = true end
    if e.jump ~= nil then fx[#fx + 1] = { t = t, kind = 'jump', v = e.jump, ease = 0, order = i * 2 } end
    local sv = e.scroll or e.sv
    if sv ~= nil then fx[#fx + 1] = { t = t, kind = 'scroll', v = sv, ease = 0, order = i * 2 + 1 } end
  end
  table.sort(fx, function(a, b)
    if a.t ~= b.t then return a.t < b.t end
    return a.order < b.order
  end)
  if not unsafe then T3DLegacy.pos = T3DTgBuild(fx) end

  for _, n in ipairs(d.note or {}) do
    local seg = n.seg
    if seg ~= nil and #seg > 0 and n.type ~= 1 then
      local hb = bt(n.beat)
      local odd, prev = false, 0
      for i = 1, #seg do
        local t = bt(seg[i].beat)
        if t < prev or t < 0 then odd = true end
        prev = t
      end
      if odd then T3DLegacy.odd = T3DLegacy.odd + 1 end
      do
        local h = ms(hb)
        local e = { t0 = h, x0 = n.x or 0, w = n.w or 0, n = #seg, dt = {}, dx = {} }
        for i = 1, #seg do
          e.dt[i] = ms(hb + bt(seg[i].beat)) - h
          e.dx[i] = seg[i].x or 0
        end
        local key = math.floor(e.t0 + 0.5)
        local list = T3DLegacy.byT[key]
        if list == nil then list = {} T3DLegacy.byT[key] = list end
        list[#list + 1] = e
        T3DLegacy.count = T3DLegacy.count + 1
      end
    end
  end
end

--- 今の譜面ファイルを読み、時刻が戻る Slide を登録する。どこかで失敗したら何もしない
function T3DLoadLegacy()
  T3DLegacy.count, T3DLegacy.odd, T3DLegacy.byT = 0, 0, {}
  T3DLegacy.pos, T3DLegacy.W, T3DLegacy.posBad = nil, nil, false
  local okP, path = pcall(T3DLegacyChartPath)
  if not okP or path == nil then
    print('[T3D] LegacySlide: 譜面のパスが取れないので使わない ' .. tostring(path))
    return
  end
  local base = string.match(path, '([^/\\]+)$')
  if base == nil or string.lower(string.sub(base, -3)) ~= '.mc' then
    print('[T3D] LegacySlide: .mc ではないので使わない ' .. tostring(base))
    return
  end
  local ok, txt = pcall(function() return Game:ReadFile(base) end)
  if not ok or type(txt) ~= 'string' or txt == '' then
    print('[T3D] LegacySlide: 譜面ファイルが読めない ' .. base)
    return
  end
  local okJ, err = pcall(T3DLegacyFromMc, txt)
  if not okJ then
    T3DLegacy.count, T3DLegacy.byT = 0, {}
    print('[T3D] LegacySlide: 譜面ファイルの解析に失敗 ' .. tostring(err))
    return
  end
  print(string.format('[T3D] LegacySlide: %s から Slide を %d 本（うち時刻が戻るもの %d 本）', base, T3DLegacy.count, T3DLegacy.odd))
end

--- ノーツに対応する登録済みの Slide を探し、元の順の点を作る。無ければ nil。
--- 各点の画面上の位置はエンジンの p（時刻順）から引くので、元の点 i -> エンジンの添字 j の対応も作る
function T3DLegacyFind(info, c)
  local key = math.floor(c.t0 + 0.5)
  local best, bestD = nil, 4
  for k = key - 2, key + 2 do
    local list = T3DLegacy.byT[k]
    if list ~= nil then
      for _, e in ipairs(list) do
        local d = math.abs(e.x0 - c.x0)
        if e.used then d = d + 2 end       -- 使用済みは後回し（始点を重ねた Slide を取り違えない）
        if e.n == c.n and d < bestD then best, bestD = e, d end
      end
    end
  end
  if best == nil then return nil end
  best.used = true
  local n = c.n
  local lg = { n = n, t = { [0] = c.t0 }, x = { [0] = c.x0 } }
  -- 最初の区間の終わり（時刻が戻る直前の点）。頭の直後で戻れば 0（判定は頭だけ）
  local firstN, broken = 0, false
  local tEnd = c.t0
  for i = 1, n do
    lg.t[i] = c.t0 + best.dt[i]
    lg.x[i] = c.x0 + best.dx[i]
    if lg.t[i] > tEnd then tEnd = lg.t[i] end
    if not broken then
      if lg.t[i] >= lg.t[i - 1] then firstN = i else broken = true end
    end
  end
  lg.firstN, lg.tEnd = firstN, tEnd
  lg.wx = {}
  for i = 0, n do lg.wx[i] = T3DWorldX(lg.x[i]) end
  -- 各点の位置（譜面の effect から。点ごとに変わらない）。
  -- エンジンは点の時刻を整数 ms に丸めているので、位置もそれに合わせる（scroll が大きい区間では 1ms の差が大きく効く）。
  -- 帯を切るかどうか（時刻が戻るか）は丸める前の時刻で決める
  local pos = T3DLegacy.pos
  if pos ~= nil then
    lg.P = {}
    -- 丸めは譜面上の絶対時刻（頭の丸め前の時刻 + 相対）で行う。エンジンの頭の時刻（丸め済み）から足すと 1ms ずれることがある
    lg.P[0] = T3DTgPos(pos, c.t0)
    for i = 1, n do lg.P[i] = T3DTgPos(pos, math.floor(best.t0 + best.dt[i] + 0.5)) end
  end
  lg.c = c
  return lg
end

--- 元の点 i -> エンジンの点の添字 j（エンジンの p を読むとき用）。初めて要るときに作る
function T3DLegacyMapJ(lg)
  if lg.j ~= nil then return lg.j end
  local c, n = lg.c, lg.n
  local j = { [0] = 0 }
  -- エンジンの点（0=頭、1〜n=時刻順）を時刻で並べ、元の点ごとに一番近い時刻の添字を取る
  local et, ej = {}, {}
  for k = 0, n do
    local tk = T3DSegPoint(c, k)
    local m = #et
    while m >= 1 and et[m] > tk do et[m + 1], ej[m + 1] = et[m], ej[m]; m = m - 1 end
    et[m + 1], ej[m + 1] = tk, k
  end
  for i = 1, n do
    local t = lg.t[i]
    local L, R = 1, #et
    while L < R do
      local mid = math.floor((L + R) / 2)
      if et[mid] < t then L = mid + 1 else R = mid end
    end
    if L > 1 and math.abs(et[L - 1] - t) < math.abs(et[L] - t) then L = L - 1 end
    j[i] = ej[L]
  end
  lg.j = j
  return j
end

function T3DSegsOf(info)
  local nid = info.nid
  local c = T3DSegCache[nid]
  if c ~= nil then return c end
  local t0, x0 = info.time, info.x
  local segs = info.segments
  c = { n = 0, t = { [0] = t0 }, x = { [0] = x0 }, t0 = t0, x0 = x0, segs = segs, endtime = info.endtime }
  if segs ~= nil then c.n = segs.Length end
  T3DSegCache[nid] = c
  if T3D.LegacySlide and T3DLegacy.count > 0 and c.n > 0 then c.lg = T3DLegacyFind(info, c) end
  return c
end

--- 点 i（0=頭）の絶対時刻と譜面x。まだ写していなければここで読む
function T3DSegPoint(c, i)
  local t = c.t[i]
  if t == nil then
    local s = c.segs[i - 1]
    t = c.t0 + s.time
    c.t[i] = t
    c.x[i] = c.x0 + s.x
  end
  return t, c.x[i]
end

--- ノーツが持つ帯の Grid の数。帯ごとに専用の Grid を持たず、そのフレームで見えている帯に順に割り当てる
function T3DBandSlots(segCount)
  if segCount > T3D.BandCap then return T3D.BandCap end
  return segCount
end

--- ノーツの segment 数（Tapなら0）
function T3DSegCount(info)
  if info == nil then return 0 end
  return T3DSegsOf(info).n
end

--- Slide/Hold の終了時刻。endtime が無ければ最終segmentの時刻を使う
function T3DSlideEndTime(info)
  local c = T3DSegsOf(info)
  if c.endT == nil then
    if c.lg ~= nil then
      c.endT = c.lg.t[c.lg.firstN]          -- LegacyMode: 判定は最初の区間だけ
    elseif c.n > 0 then
      local last = T3DSegPoint(c, c.n)
      if c.endtime ~= nil and c.endtime > last then c.endT = c.endtime else c.endT = last end
    else
      c.endT = c.endtime or c.t0
    end
  end
  return c.endT
end

--- 時刻 t における Slide の譜面x。segment を線形補間する。
--- 「t 以上の時刻を持つ最初の点」を二分探索で探し、その手前の点との間で補間する
function T3DSlideXAt(info, t)
  local c = T3DSegsOf(info)
  local lg = c.lg
  if lg ~= nil then
    -- LegacyMode: 最初の区間（時刻は単調）だけで補間する
    local fn = lg.firstN
    if fn == 0 or t <= lg.t[0] then return lg.x[0] end
    if t >= lg.t[fn] then return lg.x[fn] end
    for i = 1, fn do
      if lg.t[i] >= t then
        local span = lg.t[i] - lg.t[i - 1]
        local u = 1
        if span > 0 then u = (t - lg.t[i - 1]) / span end
        return lg.x[i - 1] + (lg.x[i] - lg.x[i - 1]) * u
      end
    end
    return lg.x[fn]
  end
  local n = c.n
  if n == 0 or t <= c.t0 then return c.x0 end
  local tn, xn = T3DSegPoint(c, n)
  if t > tn then return xn end
  local lo, hi = 1, n
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if T3DSegPoint(c, mid) >= t then hi = mid else lo = mid + 1 end
  end
  local pt, px = T3DSegPoint(c, lo - 1)
  local st, sx = T3DSegPoint(c, lo)
  local span = st - pt
  local u = 1
  if span > 0 then u = (t - pt) / span end
  return px + (sx - px) * u
end

--- 判定幅を作る。一旦ゲーム設定の判定レベルに関わらず C（Normal）に固定する。
--- ログにはゲーム設定のレベルと、追従していた場合の倍率を出す。
--- Pro(11〜15) は同じレベルの通常版をさらに狭めたものとして扱う
function T3DApplyJudgeLevel()
  local scale, name = 1, '不明'
  local ok, lv = pcall(function() return Play:GetJudge() end)
  if ok and type(lv) == 'number' then
    name = '不明(' .. lv .. ')'
    local pro = lv > 10
    local idx = pro and (lv - 10) or lv
    if JudgeScale[idx] ~= nil then
      scale = JudgeScale[idx]
      name = JudgeLevelName[idx]
      if pro then
        scale = scale * JudgeProScale
        name = name .. ' Pro'
      end
    end
  end
  for k, v in pairs(JudgeBase) do JudgeWindow[k] = v end
  print(string.format('[T3D]   判定レベル=%s(本来 x%.2f) -> C に固定: Best %.0f / Cool %.0f / Good %.0f / Miss %.0f ms',
    name, scale, JudgeWindow.Best, JudgeWindow.Cool, JudgeWindow.Good, JudgeWindow.Miss))
end

--- スコア・コンボ・精度・HP をゲーム側に反映する
function T3DPushScore()
  Play:SetScore(math.floor(T3DScore.current))
  Play:SetCombo(T3DScore.combo)
  Play:SetHP(T3DHP)
  -- コンボが一度も切れていなければフルコンボ。見るのは結果画面だけなので毎回そのまま反映してよい。
  -- Miss の数で見ないのは、Wipe の取り逃しがコンボを切らないため
  Play:SetFullCombo(not T3DScore.broken)
  for n = 1, 4 do
    Play:SetCountByType(n, T3DScore.counts[n])
  end
  -- 精度は「今までに判定した分の理論値」に対する割合
  local acc = 100
  if T3DScore.judged > 0 then
    acc = 100 * T3DScore.current / (T3DScore.judged * T3DScore.perNote)
  end
  Play:SetAcc(acc)
end

--------------------------------------------------------------------------------
-- 判定（タッチ前提）
--
-- 入力はすべて「ポインタ」として扱う。
--   タッチ    : 指1本 = ポインタ1つ。画面上の高さで床 / 空中を分け、床なら逆射影で譜面 x を出す
--   キーボード: キー1つ = ポインタ1つ。床のキーはレーン区間を、空中のキーはゾーンを持つ
-- 判定はポインタだけを見るので、タッチとキーボードで判定ルールが分かれない。
-- 例外はフリックだけで、キーボードは方向を入れられないため押した時点で成立させる。
--------------------------------------------------------------------------------

--- 判定結果をスコア・コンボ・演出に反映する（床 / 空中を問わない共通部分）。
--- quiet = true なら TapEffect と判定表示を出さない
--- keepCombo = true なら Miss でもコンボを切らない（Wipe 用）
function T3DScoreJudge(result, worldX, worldY, quiet, keepCombo)
  if not quiet then
    if result ~= JudgeType.Miss and T3D.HitFx then
      T3DSafe('HitFx', function() T3DSpawnHitFx(worldX, Game:Time(), worldY) end)
    end
    if T3D.JudgeText then
      T3DSafe('JudgeText', function() T3DShowJudgeText(result, Game:Time()) end)
    end
  end
  T3DScore.counts[result] = T3DScore.counts[result] + 1
  T3DScore.judged = T3DScore.judged + 1
  T3DHP = T3DHP + HPDelta[result]
  if T3DHP > 100 then T3DHP = 100 elseif T3DHP < HPFloor then T3DHP = HPFloor end
  T3DScore.current = T3DScore.current + T3DScore.perNote * JudgeWeight[result]
  if result == JudgeType.Miss then
    -- Wipe は取り逃してもコンボを切らない（2026-09-20 ユーザー指定）。
    -- 切れていない以上フルコンボも保つので、Miss の数ではなく「切れたか」で持つ
    if not keepCombo then
      T3DScore.combo = 0
      T3DScore.broken = true
    end
  else
    T3DScore.combo = T3DScore.combo + 1
    if T3DScore.combo > T3DScore.maxCombo then
      T3DScore.maxCombo = T3DScore.combo
    end
  end
  -- Hold の完走は quiet で来てもコンボは増えるので、quiet でも呼ぶ（100コンボ目が完走のこともある）
  if T3D.Fx then T3DSafe('FxJudge', T3DFxOnJudge, result, keepCombo) end
  T3DPushScore()
end

--- 床ノーツの判定を確定させる。quiet は T3DScoreJudge と同じ
function T3DApplyJudge(info, result, quiet)
  if T3DJudged[info.nid] then return end
  T3DJudged[info.nid] = true
  -- Wipe(type 4 / フリック付き 6) は取り逃してもコンボを切らない
  local keepCombo = (info.type == 4 or info.type == 6)
  T3DScoreJudge(result, T3DWorldX(info.x), 0, quiet, keepCombo)
  Play:SetNoteFinish(info.nid)
end

--- 時刻のずれ(ms) -> 判定。Good 圏外なら nil
function T3DGrade(offset)
  local a = math.abs(offset)
  if a <= JudgeWindow.Best then return JudgeType.Best end
  if a <= JudgeWindow.Cool then return JudgeType.Cool end
  if a <= JudgeWindow.Good then return JudgeType.Good end
  return nil
end

--- ポインタが、layer('floor' / 'air') 上の中心 x・幅 w の範囲に触れているか。
--- 床と空中で同じ規則を使う
function T3DPointerCovers(ptr, layer, x, w)
  if ptr == nil or not ptr.down or ptr.layer ~= layer then return false end
  local half = math.max(w or 0, 16) * 0.5
  if ptr.laneL ~= nil then
    -- キー: そのキーのレーン区間と要素の幅が重なっていれば取れる。
    -- 幅がレーン境界を跨ぐ要素は、跨いだどちらのキーでも取れる
    return (x + half) > ptr.laneL + 2 and (x - half) < ptr.laneR - 2
  end
  -- タッチ: 指の位置が要素の幅の中（少し余裕を持たせる）
  return math.abs(ptr.x - x) <= half + InputConf.TouchTolerance
end

--- layer 上の範囲に触れているポインタが1つでもあるか
function T3DAnyCovers(layer, x, w)
  for _, ptr in pairs(T3DPointers) do
    if T3DPointerCovers(ptr, layer, x, w) then return true end
  end
  return false
end

--------------------------------------------------------------------------------
-- 床
--------------------------------------------------------------------------------

--- Hold/Slide の押下を始める。判定表示は押した瞬間に出し、完走時は quiet で確定する
function T3DStartHold(info, result, auto)
  T3DHolds[info.nid] = { info = info, pending = result, auto = auto, lostAt = nil }
  local now = Game:Time()
  if T3D.HitFx then
    T3DSafe('HitFx', function() T3DSpawnHitFx(T3DWorldX(info.x), now, 0) end)
  end
  if T3D.JudgeText then
    T3DSafe('JudgeText', function() T3DShowJudgeText(result, now) end)
  end
  if T3D.HoldFx then
    T3DSafe('HoldFx', function() T3DAttachHoldFx('floor', info.nid, now) end)
  end
end

--- 仮想ノーツを除いた Play:FindNoteByTime。key ごとに結果の表を使い回す（毎回作るとゴミになる）
function T3DFindNotes(lo, hi, key)
  local notes = Play:FindNoteByTime(lo, hi)
  if notes == nil or T3DVirt.count == 0 then return notes end
  local buf = T3DVirt.bufs[key]
  if buf == nil then
    buf = { Length = 0 }
    T3DVirt.bufs[key] = buf
  end
  local n, skipped = 0, 0
  for i = 0, notes.Length - 1 do
    local x = notes[i]
    if x.type < T3DVirt.base then
      buf[n] = x
      n = n + 1
    else
      skipped = skipped + 1
    end
  end
  for i = n, buf.Length - 1 do buf[i] = nil end
  buf.Length = n
  return buf
end

--- 押下をどのノーツに当てるか。候補は触れていて Good 以内のもの。
--- first = 判定時刻が最も早い候補、near = 判定時刻が最も近い候補。
--- 前のノーツに遅れて押したなら、Cool 以内の遅れまでは前のノーツのもの（first）。
--- 近いほう一択だと、縦連で少し遅れた押下が次のノーツに吸われ、前のノーツが MISS になる。
--- それより遅れていたら前は飛ばしたとみなし、近いほう（near）を取る
function T3DPressChoice(first, near, t)
  if first ~= nil and t - first.time <= JudgeWindow.Cool then return first end
  return near
end

--- 床のポインタが押された。触れている範囲から T3DPressChoice の規則で1つ取る
function T3DJudgeFloorPress(ptr, t)
  local notes = T3DFindNotes(-JudgeWindow.Good, JudgeWindow.Good, 'press')
  if notes == nil then return end

  local first, near, nearAbs = nil, nil, 99999
  for i = 0, notes.Length - 1 do
    local n = notes[i]
    if T3DHolds[n.nid] == nil and not T3DFlickPending[n.nid] and not T3DJudged[n.nid]
        and T3DPointerCovers(ptr, 'floor', n.x, n.width) then
      local a = math.abs(n.time - t)
      if a <= JudgeWindow.Good then
        if a < nearAbs then near, nearAbs = n, a end
        if first == nil or n.time < first.time then first = n end
      end
    end
  end
  local best = T3DPressChoice(first, near, t)
  if best == nil then return end
  -- 選んだのが Hold/Slide の始点なら、この押下はそれのもの。押して取るのではなく、
  -- 重なっていれば始まる（T3DUpdateTouchNotes）。すぐ後ろのノーツを早押しで取らないよう、他にも回さない
  if T3DSegCount(best) > 0 then return end

  local result = T3DGrade(best.time - t)
  if result == nil then return end   -- Good 圏外は空打ち。ノーツは消さない

  if best.type == 5 or best.type == 6 then
    if ptr.isKey then
      T3DApplyJudge(best, result)
    else
      -- 押した時点の判定を保留し、矢印の方向へ動かしたら成立（T3DCheckFlick）
      T3DFlickPending[best.nid] = true
      ptr.flick = { info = best, grade = result, sx = ptr.sx, sy = ptr.sy, t = Game:Time() }
    end
  else
    T3DApplyJudge(best, result)
  end
end

--- ポインタの移動でフリックが成立したか見る。arrow: 1=左 2=上 3=右
function T3DCheckFlick(ptr)
  local f = ptr.flick
  if f == nil then return end
  local dx, dy = ptr.sx - f.sx, ptr.sy - f.sy
  local a = f.info.arrow
  local done = (a == 1 and dx <= -FlickConf.Dist)
            or (a == 3 and dx >= FlickConf.Dist)
            or (a == 2 and dy >= FlickConf.Dist)
  if done then
    T3DFlickPending[f.info.nid] = nil
    ptr.flick = nil
    T3DApplyJudge(f.info, f.grade)
  end
end

--- フリックの不成立（離した / 時間切れ）
function T3DFailFlick(ptr)
  local f = ptr.flick
  if f == nil then return end
  T3DFlickPending[f.info.nid] = nil
  ptr.flick = nil
  T3DApplyJudge(f.info, JudgeType.Miss)
end

function T3DUpdateFlicks()
  local now = Game:Time()
  for _, ptr in pairs(T3DPointers) do
    if ptr.flick ~= nil and now - ptr.flick.t > FlickConf.TimeoutMs then
      T3DFailFlick(ptr)
    end
  end
end

--- 押し直し不要で、重なっていれば取れる床のノーツ。
--- Wipe: 判定は「重なった時刻」で決まるので、判定時刻の前から触れていれば BEST、遅れて触れれば COOL / GOOD。
--- Hold/Slide: 始点の判定は無い（AirSlide と同じ）。始点の時刻に帯の位置へ触れていれば始まり、途中で切れなければ BEST。
---   押しっぱなしで入ってもよいので、AirSlide から AirLift で降りてきた指でそのまま取れる。
---   AirConf.StartGraceMs までに触れなければ切れた扱い（途中から触れれば復活できる）
--- FindNoteByTime を増やさないよう、両方を1回の検索で見る
function T3DUpdateTouchNotes(t)
  local lo = math.max(JudgeWindow.Good, AirConf.StartGraceMs)
  local notes = T3DFindNotes(-lo, InputConf.WipeLeadMs, 'touch')
  if notes == nil then return end
  for i = 0, notes.Length - 1 do
    local n = notes[i]
    if not T3DJudged[n.nid] and T3DHolds[n.nid] == nil then
      local d = n.time - t
      if T3DSegCount(n) > 0 then
        if d <= 0 then
          if T3DAnyCovers('floor', T3DSlideXAt(n, t), n.width) then
            T3DStartHold(n, JudgeType.Best, false)
          elseif -d > AirConf.StartGraceMs then
            T3DMissHold(n, t)
          end
        end
      elseif n.type == 4 and d <= InputConf.WipeLeadMs and d >= -JudgeWindow.Good
          and T3DAnyCovers('floor', n.x, n.width) then
        local result = T3DGrade(d)
        if result ~= nil then T3DApplyJudge(n, result) end
      end
    end
  end
end

--- 始まらなかった Hold/Slide を、消さずに切れた状態で流す。途中から触れれば復活できる
function T3DMissHold(n, t)
  local h = { info = n, pending = JudgeType.Miss, auto = false }
  T3DHolds[n.nid] = h
  T3DBreakHold(h, t)
end

--- 押下中の Hold/Slide。その時点の帯の位置にポインタが重なっているかを見る。
--- 一瞬外れても InputConf.ReleaseGraceMs までは切らない
--- Hold/Slide を「切れた」状態にする。消さずに薄く表示し続け、もう一度触れれば復活できる。
--- MISS は最初に切れたときに1回だけ数える（復活してから押し切っても MISS のまま）
function T3DBreakHold(h, t)
  h.broken = true
  h.lostAt = nil
  if not h.judged then
    h.judged = true
    -- 帯を持つ Wipe（この譜面では見かけないが書ける）も、単発と同じくコンボを切らない
    local keepCombo = (h.info.type == 4 or h.info.type == 6)
    T3DScoreJudge(JudgeType.Miss, T3DWorldX(T3DSlideXAt(h.info, t)), 0, false, keepCombo)
  end
end

--- 押下中・切れた状態の Hold/Slide を毎フレーム見る。
--- その時点の帯の位置にポインタが重なっているか。一瞬外れても InputConf.ReleaseGraceMs までは切らない
function T3DUpdateHolds(t)
  for nid, h in pairs(T3DHolds) do
    local info = h.info
    local endT = T3DSlideEndTime(info)
    if t >= endT then
      if not h.judged then
        -- 一度も切れずに完走。頭を押した時の判定を確定させる（判定表示は頭で出し済み）
        T3DApplyJudge(info, h.pending, true)
      else
        -- 切れた時点で MISS を数え済みなので、ノーツを終わらせるだけ
        T3DJudged[info.nid] = true
        Play:SetNoteFinish(info.nid)
      end
      if not h.broken and T3D.HitFx then
        T3DSafe('HitFx', function()
          T3DSpawnHitFx(T3DWorldX(T3DSlideXAt(info, endT)), Game:Time(), 0)
        end)
      end
      T3DHolds[nid] = nil
    else
      local held = h.auto or T3DAnyCovers('floor', T3DSlideXAt(info, t), info.width)
      if held then
        h.lostAt = nil
        if h.broken then
          -- 復活: 明るい表示と Hold エフェクトを戻す
          h.broken = false
          if T3D.HoldFx then
            T3DSafe('HoldFx', function() T3DAttachHoldFx('floor', nid, Game:Time()) end)
          end
        end
      elseif not h.broken then
        if h.lostAt == nil then h.lostAt = t end
        if t - h.lostAt > InputConf.ReleaseGraceMs then
          T3DBreakHold(h, t)
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 空中
--------------------------------------------------------------------------------

--- 空中のポインタが押された。触れている範囲の AirTap から1つ取る（床と同じ規則: T3DPressChoice）
function T3DJudgeAirPress(ptr, t)
  local first, near, nearAbs = nil, nil, 99999
  for _, tap in ipairs(T3DAirTaps) do
    if not tap.judged then
      local a = math.abs(tap.time - t)
      if a <= JudgeWindow.Good and T3DPointerCovers(ptr, 'air', tap.x, tap.w) then
        if a < nearAbs then near, nearAbs = tap, a end
        if first == nil or tap.time < first.time then first = tap end
      end
    end
  end
  local best = T3DPressChoice(first, near, t)
  if best == nil then return end

  local result = T3DGrade(best.time - t)
  if result == nil then return end
  best.judged = true
  T3DScoreJudge(result, T3DWorldX(best.x), T3DWorldY(255), false)
end

--- AirSlide の1区間の、時刻 t における譜面 x と高さ(0〜255)
function T3DAirSlidePos(r, t)
  local u = 1
  if r.e > r.s then u = (t - r.s) / (r.e - r.s) end
  local k = T3DEase(u, r.ease)
  return r.x1 + (r.x2 - r.x1) * k, r.y1 + (r.y2 - r.y1) * k
end

--- AirSlide を取れているか。空中でその位置・幅に触れていれば取れる（床と同じ規則）。
--- 縦移動(Lift)だけは、床の同じ位置・幅を押していても可
--- （タッチなら床から上へ指を滑らせる動きがそのまま通る）
function T3DAirSlideHeld(r, t)
  if T3DAuto then return true end
  local x = T3DAirSlidePos(r, t)
  if T3DAnyCovers('air', x, r.w) then return true end
  if r.x1 == r.x2 and r.y1 ~= r.y2 then
    return T3DAnyCovers('floor', x, r.w)
  end
  return false
end

--- AirSlide の区間を「切れた」状態にする。消さずに薄く表示し、もう一度触れれば復活できる。
--- MISS は最初に切れたときに1回だけ数える
function T3DBreakAirSlide(r, t)
  r.state = 'broken'
  r.lostAt = nil
  if not r.judged then
    r.judged = true
    local x, y = T3DAirSlidePos(r, t)
    T3DScoreJudge(JudgeType.Miss, T3DWorldX(x), T3DWorldY(y), false)
  end
end

--- AirSlide は押し始めの時刻を問わない。区間の間ずっと取れていれば BEST、途中で切れたら MISS。
--- 状態: nil(開始前/開始待ち) -> 'active'(取れている) <-> 'broken'(切れた・薄く表示) -> 'done'(終了)
function T3DUpdateAirJudge(t)
  for _, r in ipairs(T3DAirSlides) do
    -- 直角（長さ0の Lift）は継ぎ目の見た目だけ。押さえ続ける時間が無いので判定しない
    if r.instant then
      r.state = 'done'
    elseif r.state ~= 'done' and t >= r.s then
      if t >= r.e then
        if not r.judged then
          r.judged = true
          local x, y = T3DAirSlidePos(r, r.e)
          if r.state == 'active' then
            T3DScoreJudge(JudgeType.Best, T3DWorldX(x), T3DWorldY(y), false)
          else
            T3DScoreJudge(JudgeType.Miss, T3DWorldX(x), T3DWorldY(y), false)
          end
        end
        r.state = 'done'
      elseif T3DAirSlideHeld(r, t) then
        -- 取れている。開始待ちからの開始も、切れた状態からの復活もここ
        if r.state ~= 'active' then
          r.state = 'active'
          if T3D.HoldFx then
            T3DSafe('HoldFx', function() T3DAttachHoldFx('air', r, Game:Time()) end)
          end
        end
        r.lostAt = nil
      elseif r.state == nil then
        -- 開始から AirConf.StartGraceMs 以内に取れなければ切れた扱い
        if t > r.s + AirConf.StartGraceMs then
          T3DBreakAirSlide(r, t)
        end
      elseif r.state == 'active' then
        if r.lostAt == nil then r.lostAt = t end
        if t - r.lostAt > InputConf.ReleaseGraceMs then
          T3DBreakAirSlide(r, t)
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 見逃し / Auto / リトライ
--------------------------------------------------------------------------------

--- 判定枠を過ぎたものを Miss にする。押下中の Hold と、フリック待ちのノーツは除く
function T3DAutoMiss(t)
  local notes = T3DFindNotes(-3000, -JudgeWindow.Miss - 1, 'miss')
  if notes ~= nil then
    for i = 0, notes.Length - 1 do
      local n = notes[i]
      if T3DHolds[n.nid] == nil and not T3DFlickPending[n.nid] then
        if T3DSegCount(n) > 0 then
          -- 始まらなかった Hold/Slide も消さない。開始の猶予（判定レベルで Miss の枠より長いことがある）は待つ
          if t - n.time > AirConf.StartGraceMs then T3DMissHold(n, t) end
        else
          T3DApplyJudge(n, JudgeType.Miss)
        end
      end
    end
  end
  for _, tap in ipairs(T3DAirTaps) do
    if not tap.judged and tap.time < t - JudgeWindow.Miss then
      tap.judged = true
      T3DScoreJudge(JudgeType.Miss, T3DWorldX(tap.x), T3DWorldY(255), false)
    end
  end
end

--- Auto プレイ: 判定時刻が来たものを全部 BEST で処理する。AirSlide は T3DAirSlideHeld が常に真を返す
function T3DUpdateAuto(t)
  local notes = T3DFindNotes(-JudgeWindow.Miss, 0, 'auto')
  if notes ~= nil then
    for i = 0, notes.Length - 1 do
      local n = notes[i]
      if n.time <= t and T3DHolds[n.nid] == nil then
        if T3DSegCount(n) > 0 then
          T3DStartHold(n, JudgeType.Best, true)
        else
          T3DApplyJudge(n, JudgeType.Best)
        end
      end
    end
  end
  for _, tap in ipairs(T3DAirTaps) do
    if not tap.judged and tap.time <= t then
      tap.judged = true
      T3DScoreJudge(JudgeType.Best, T3DWorldX(tap.x), T3DWorldY(255), false)
    end
  end
end

--- リトライ時に、プレイ中に変化する状態をすべて初期状態へ戻す
function T3DResetPlayState()
  T3DScore.current, T3DScore.combo, T3DScore.maxCombo, T3DScore.judged = 0, 0, 0, 0
  T3DScore.broken = false
  T3DScore.counts = { 0, 0, 0, 0 }
  T3DHolds = {}
  T3DJudged = {}
  T3DHiddenNote = {}
  T3DHP = HPStart
  T3DFlickPending = {}
  T3DPointers = {}
  T3DLaneDown = { false, false, false, false }
  T3DAirLaneDown = { false, false, false, false }
  T3DSkyIndex = 1
  for ch in pairs(T3DCamEvents) do T3DCamIndex[ch] = 1 end
  -- 仮想ノーツの読み取りを捨てる。時刻が戻るので、前のプレイで読んだもの（at が今より後）が残っていると
  -- T3DElemZ が「たった今読んだ」とみなし、空中要素・小節線・トレースが前の位置に残り続ける。
  -- 記録そのものは、このあと呼び直される OnProcessNote（T3DAddVirtuals）で作り直す。
  -- 実機では OnRetry からそこまで約2秒あり、その間の描画のためにここでも捨てておく
  for _, rec in pairs(T3DVirt.byT) do rec.rem, rec.at = nil, nil end
  T3DVirt.rate = 0
  if T3D.Fx then T3DResetFx() end

  for _, tap in ipairs(T3DAirTaps) do tap.judged = nil end
  for _, r in ipairs(T3DAirSlides) do
    r.state = nil
    r.lostAt = nil
    r.judged = nil
  end

  for s = 1, HitFxConf.Slots do
    local slot = T3DHitFx[s]
    if slot ~= nil then
      if slot.cur >= 0 and slot.frames[slot.cur] ~= nil then T3DSetA(slot.frames[slot.cur], 0) end
      slot.active = false
      slot.cur = -1
    end
  end
  for s = 1, HoldFxConf.Slots do
    local slot = T3DHoldFx[s]
    if slot ~= nil then
      if slot.cur >= 0 and slot.frames[slot.cur] ~= nil then T3DSetA(slot.frames[slot.cur], 0) end
      slot.ref = nil
      slot.kind = nil
      slot.cur = -1
    end
  end
  if T3DJudgeText.kind > 0 and T3DJudgeText.cur >= 0 then
    local q = T3DJudgeText.frames[T3DJudgeText.kind][T3DJudgeText.cur]
    if q ~= nil then T3DSetA(q, 0) end
  end
  T3DJudgeText.kind = 0
  T3DJudgeText.cur = -1

  T3DPushScore()
end

function OnRetry()
  T3DSafe('Retry', T3DResetPlayState)
  -- 演出を消してから設定を反映する（非表示にした演出が表示中のまま残らないように）
  T3DSafe('RetrySettings', T3DReloadSettings)
  print('[T3D] リトライ: プレイ状態を初期化')
end

--------------------------------------------------------------------------------
-- ポインタ
--------------------------------------------------------------------------------

--- ポインタを押す。押した瞬間の判定を行う
function T3DPointerDown(id, ptr, t)
  ptr.down = true
  T3DPointers[id] = ptr
  -- Auto 中は入力で判定しない。触った拍子に早い判定が付いて点が下がるのを防ぐ
  if T3DAuto then return end
  if ptr.layer == 'floor' then
    T3DJudgeFloorPress(ptr, t)
  else
    T3DJudgeAirPress(ptr, t)
  end
end

--- ポインタを離す。フリック待ちのまま離したら不成立
function T3DPointerUp(id)
  local ptr = T3DPointers[id]
  if ptr == nil then return end
  if ptr.flick ~= nil then T3DFailFlick(ptr) end
  T3DPointers[id] = nil
end

--- 画面座標 -> 空中判定線の上での譜面 x。
--- 空中判定線(高さ一定・z=0)の上では投影スケールが一定なので、Roll を戻して割るだけで求まる
function T3DScreenToSkyX(sx, sy)
  local _, _, s = T3DProject(0, T3DWorldY(255), 0)
  if s == nil or s <= 0 then return nil end
  local px, py = sx, sy
  if Cam.Roll ~= 0 then
    local r = -math.rad(Cam.Roll)
    local cr, sr = math.cos(r), math.sin(r)
    local ox, oy = px - T3DRollPivotX, py - T3DRollPivotY
    px = T3DRollPivotX + ox * cr - oy * sr
    py = T3DRollPivotY + ox * sr + oy * cr
  end
  py = py - Cam.ShiftY
  local wx = px / s + Cam.X
  return (wx / T3DTrackW + 0.5) * 255
end

--- タッチの画面座標から、床 / 空中の別と譜面 x を求める。
--- 床の判定線と空中判定線の中間より上を触ったら空中とみなす
function T3DTouchPointer(hx, hy)
  local sx = hx - GameWidth * 0.5
  local sy
  if InputConf.TouchYOrigin == 'top' then
    sy = GameHeight * 0.5 - hy
  else
    sy = hy - GameHeight * 0.5
  end
  -- 画面の揺れで動いた分を戻す（見えている位置を触れば取れるように）
  sx, sy = sx - T3DWarp.shakeX, sy - T3DWarp.shakeY
  local ptr = { sx = sx, sy = sy, isKey = false }

  if sy >= JudgeScreenY + SkyLineConf.ScreenOffset * T3DZoomNow * 0.5 then
    ptr.layer = 'air'
    ptr.x = T3DScreenToSkyX(sx, sy) or 127.5
  else
    ptr.layer = 'floor'
    local wx = T3DUnproject(sx, sy)
    if wx == nil then wx = 0 end
    ptr.x = (wx / T3DTrackW + 0.5) * 255
  end
  return ptr
end

--- タッチ入力（Type: 1=押す 2=動かす 3=離す、Source: 指の番号）
function OnInput()
  if not T3DAlive or not T3D.Judge then return end
  local e = Game:InputEvent()
  if e == nil then return end

  local src, ty = e:Source(), e:Type()
  local hx = e:HitX()
  local okY, hy = pcall(function() return e:HitY() end)
  if not okY or hy == nil then hy = 0 end
  local id = 'touch' .. tostring(src)
  local now = Game:Time()

  if ty == 3 then
    T3DSafe('TouchUp', function()
      -- 素早いフリックは、成立する距離に届く前に指が離れて移動イベントが来ないことがある。
      -- 離した位置も移動の続きとして見てから、ポインタを片付ける
      -- 離したイベントで座標が来ない機種もあるので、(0,0) のときは位置を信用しない
      local ptr = T3DPointers[id]
      if ptr ~= nil and ptr.flick ~= nil and (hx ~= 0 or hy ~= 0) then
        local fresh = T3DTouchPointer(hx, hy)
        ptr.sx, ptr.sy = fresh.sx, fresh.sy
        T3DCheckFlick(ptr)
      end
      T3DPointerUp(id)
    end)
  else
    local fresh = T3DTouchPointer(hx, hy)
    local ptr = T3DPointers[id]
    if ty == 1 or ptr == nil then
      T3DSafe('TouchDown', function() T3DPointerDown(id, fresh, now) end)
    else
      -- 移動: 位置と床/空中の別だけ更新する（押し直しにはしない）。フリックの成立もここで見る
      ptr.sx, ptr.sy = fresh.sx, fresh.sy
      ptr.layer, ptr.x = fresh.layer, fresh.x
      T3DSafe('TouchMove', function() T3DCheckFlick(ptr) end)
    end
  end

  if ty ~= 2 and T3DInputLogged < 40 then
    T3DInputLogged = T3DInputLogged + 1
    local p = T3DPointers[id]
    -- 指の位置が判定とずれていたら、raw と sy を見比べて InputConf.TouchYOrigin を切り替える。
    -- 床の判定線と空中判定線の画面Yも一緒に出しているので、どちらへずれているか分かる
    print(string.format(
      '[T3D] touch type=%d src=%s raw(%.0f, %.0f) -> sy=%.0f %s x=%s (判定線 sy=%d / 空中 sy=%d)',
      ty, tostring(src), hx, hy,
      p and p.sy or 0, p and p.layer or '-', p and string.format('%.0f', p.x) or '-',
      JudgeScreenY, math.floor(JudgeScreenY + SkyLineConf.ScreenOffset * T3DZoomNow)))
  end
end

--- キーボード入力（PC での確認用）。床のキーも空中のキーも、レーン区間を持つポインタになる
function OnKey()
  local e = Game:InputEvent()
  if e == nil then return end

  local ty, key = e:Type(), e:Source()
  local lane = T3DKeyLane[key]
  local airLane = T3DAirKeyLane[key]
  local id = 'key' .. tostring(key)
  local down = (ty ~= 3)

  if lane ~= nil then T3DLaneDown[lane] = down end
  if airLane ~= nil then T3DAirLaneDown[airLane] = down end

  if lane ~= nil or airLane ~= nil then
    if not down then
      T3DSafe('KeyUp', function() T3DPointerUp(id) end)
    elseif T3DPointers[id] == nil then
      -- 押した瞬間だけ判定する（キーリピートで多重判定しないよう、既に押していれば何もしない）
      local laneW = 256 / T3DLanes
      local k = lane or airLane
      local ptr = { isKey = true, sx = 0, sy = 0 }
      if lane ~= nil then ptr.layer = 'floor' else ptr.layer = 'air' end
      ptr.laneL, ptr.laneR = (k - 1) * laneW, k * laneW
      ptr.x = (k - 0.5) * laneW
      if T3DAlive and T3D.Judge then
        T3DSafe('KeyDown', function() T3DPointerDown(id, ptr, Game:Time()) end)
      else
        ptr.down = true
        T3DPointers[id] = ptr
      end
    end
  elseif down and T3DKeyLogged < 20 then
    T3DKeyLogged = T3DKeyLogged + 1
    print(string.format('[T3D] 未割当のキー key=%s', tostring(key)))
  end
end


--------------------------------------------------------------------------------
-- 床ノーツの描画
--   Free Mode では OnDrawNote / OnNoteMove の宣言が必須。
--   宣言しないと Init すら呼ばれずに [ScenePlay] load error になる
--------------------------------------------------------------------------------
--- ノーツ種別 -> 頭のテクスチャ。Wipe系だけ別素材にする
function T3DHeadTex(noteType)
  if noteType == 4 or noteType == 6 then return TexWipe end
  return TexTap
end

function OnDrawNote(info)
  if info.type >= T3DVirt.base then
    -- 仮想ノーツ（目印）。空のコンテナだけ用意する
    Note:GetNoteModule('t3d-virtual')
    return
  end
  local segCount = T3DSegCount(info)
  local headTex = T3DHeadTex(info.type)

  -- コンテナは「構造が同じものだけ」使い回される。segment数が違えば子要素の数も
  -- 違うので、名前を分けないと再利用の対象を取り違える
  -- 素材が違うものを同じコンテナ名にすると使い回しで取り違えるので、
  -- 「種別 + segment数」で名前を分ける
  local kind = (headTex == TexWipe) and 'wipe' or 'tap'

  -- フリックは矢印の向きごとに素材が違うので、向きもコンテナ名に含める
  local flickTex, flickIdx = nil, nil
  if T3D.Flick then flickTex, flickIdx = T3DFlickTex(info) end
  if flickIdx ~= nil then kind = kind .. '-flick' .. flickIdx end

  -- モノクロの区間に奥に現れるノーツは灰色の素材で作る。素材が違うのでコンテナ名も分ける
  if T3DFxMonoNote(info) then
    headTex = FxConf.MonoTex[headTex] or headTex
    if flickTex ~= nil then flickTex = 'mono-' .. flickTex end
    kind = kind .. '-mono'
  end

  local root
  if segCount == 0 then
    root = Note:GetNoteModule('t3d-' .. kind)
  else
    root = Note:GetNoteModule('t3d-' .. kind .. '-slide-' .. T3DBandSlots(segCount))
  end
  if root == nil then return end

  -- 床に寝かせるので Grid。帯を奥から手前の順に貼る（後に貼るほど手前に来る）
  pcall(function()
    for i = T3DBandSlots(segCount), 1, -1 do
      root:AddGrid('seg' .. i, TexLong)
    end
    root:AddGrid('head', headTex)
    if flickTex ~= nil then
      root:AddGrid('arrow', flickTex)
    end
  end)
end

function OnNoteMove(info, mod, p)
  if info.type >= T3DVirt.base then
    T3DSafe('仮想ノーツ', T3DVirtMove, info, p)
    return
  end
  local perf = T3DPerf
  if perf == nil then return T3DNoteMove(info, mod, p) end
  perf.noteFrame = perf.noteFrame + 1
  if T3DClock == nil then return T3DNoteMove(info, mod, p) end
  local t0 = T3DClock()
  T3DNoteMove(info, mod, p)
  perf.moveFrame = perf.moveFrame + (T3DClock() - t0) * 1000
end

-- 折れ線の点のバッファ。OnNoteMove は1個ずつ順に呼ばれるので使い回せる
-- （毎回テーブルを作るとノーツ数 x フレーム数のゴミになり、GC でカクつく）
local T3DBufX, T3DBufZ = {}, {}

-- ノーツの部品の Order。奥行きに応じて少しずつ下げる（手前のノーツほど手前に来る）
local NoteOrder = { Head = 800, Arrow = 805, Band = 790 }

--- p の添字 lo〜hi のうち、奥行き z = (1 - p[i]) * depthK が limit を**超える**
--- （strict = false なら limit **以上**になる）最初の添字。無ければ hi + 1。
--- p は時刻の遅い点ほど小さい（= z は添字とともに増える）ので二分探索できる。
--- p[i] の読み出しも C# 側の呼び出しなので、中継点が数百ある Slide でも log2(n) 回で済ませる
function T3DFirstZ(p, lo, hi, depthK, limit, strict, linear)
  if linear then
    -- 逆走のある TimingGroup は z が添字順に増えるとは限らないので、頭から順に見る
    for i = lo, hi do
      local z = (1 - p[i]) * depthK
      if (strict and z > limit) or ((not strict) and z >= limit) then return i end
    end
    return hi + 1
  end
  local L, R = lo, hi + 1
  while L < R do
    local mid = math.floor((L + R) / 2)
    local z = (1 - p[mid]) * depthK
    local over
    if strict then over = z > limit else over = z >= limit end
    if over then R = mid else L = mid + 1 end
  end
  return L
end

--- 空中要素用に「出現から判定までの時間」を実測する（最初の1回だけ。以後は固定）。
--- p は 0=出現 1=判定 なので、scroll 1 なら 残り時間 / (1-p) がそのまま窓の長さになる。
--- 測り続けると、譜面の scroll が 1 以外の区間で窓がずれていく
function T3DMeasureWindow(info, prog)
  if prog <= 0.05 or prog >= 0.9 then return end
  local w = (info.time - Game:Time()) / (1 - prog)
  if w > 200 and w < 30000 then
    T3DScrollWindow = w
    T3DScrollMeasured = true
    print(string.format('[T3D] ノーツ速度: 実測の窓=%.0fms / T3DSpeed=%.1f -> 見えている時間=%.0fms',
      T3DScrollWindow, T3DSpeed, T3DLeadMs()))
  end
end

--- 描かないノーツ（奥すぎる / 帯を通過し終わった / 判定済み）の子を消す。
--- 状態が変わった1回だけ消す（T3DHiddenNote）。kids を省くと、消すときだけ引く
function T3DHideNote(info, mod, kids)
  if T3DHiddenNote[info.nid] then return end
  T3DHiddenNote[info.nid] = true
  T3DHideNoteChildren(kids or T3DKidsOf(mod, info, T3DSegCount(info)))
end

--- 切れた Hold/Slide か。切れたものは消さずに、全体を灰色寄りの薄い色で描く
--- （触れ直すと T3DUpdateHolds で元に戻る）。戻り値: 切れているか, 不透明度の倍率
function T3DNoteBroken(nid)
  local h = T3DHolds[nid]
  if h ~= nil and h.broken then return true, BrokenConf.Dim end
  return false, 1
end

--- 切れているかに合わせて色を塗る。色は子ごとに「最後に塗った色」を覚えて、違うときだけ塗る
--- （SetColor も C# 側の呼び出し）。切れた瞬間にまだ描いていなかった区間も、描くときに塗られる
function T3DTintBroken(q, broken)
  if broken then
    T3DSetTint(q, true, BrokenConf.R, BrokenConf.G, BrokenConf.B)
  else
    T3DSetTint(q, false, 255, 255, 255)
  end
end

--- ノーツの半幅（ワールド単位）
function T3DNoteHalfW(info)
  local halfW = (info.width / 255) * T3DTrackW * 0.5
  if halfW < 20 then halfW = 20 end
  return halfW
end

--- 頭を床に寝かせて描く。z はノーツの「中心」の奥行き（手前の辺を z にすると、
--- 止まったとき見た目の中心が判定線より奥にずれ、Slide の帯の始点ともずれる）。描けたら true
function T3DDrawHead(head, x, z, halfW, broken, a)
  local nd = T3DNoteDepth * 0.5
  if not T3DSetQuad(head, x - halfW, x + halfW, z - nd, z + nd, 0) then return false end
  T3DTintBroken(head, broken)
  T3DSetA(head, a)
  T3DSetOrder(head, NoteOrder.Head - math.floor(z * 0.1))
  return true
end

--- フリック矢印。ノーツの少し上にカメラ正対で浮かべる（床に寝かせると向きが読みにくい）
function T3DDrawArrow(arrow, x, z, broken, a)
  local ax, ay, as = T3DProject(x, FlickConf.Lift, z)
  if ax == nil then
    T3DSetA(arrow, 0)
  elseif T3DSetBillboard(arrow, ax, ay, (T3DTrackW / T3DLanes) * FlickConf.Size * 0.5 * as) then
    T3DTintBroken(arrow, broken)
    T3DSetA(arrow, a)
    T3DSetOrder(arrow, NoteOrder.Arrow - math.floor(z * 0.1))   -- 頭より手前
  end
end

--- 帯の Grid を1枚、手前 (ax, az) から奥 (bx, bz) へ貼る。貼れたら true
function T3DDrawBand(band, ax, az, bx, bz, half, broken, a)
  if band == nil or not T3DSetBand(band, ax, az, bx, bz, half, 0) then return false end
  T3DTintBroken(band, broken)
  T3DSetA(band, a)
  T3DSetOrder(band, NoteOrder.Band - math.floor(bz * 0.1))   -- 頭より奥に置く
  return true
end

--- 帯（点 a〜点 b）を、床ノーツが見える範囲 z = 0 〜 T3DDepth に切り詰める。見えなければ nil。
---   手前: 判定線を跨ぐ区間は交点で切る（x を据え置くと横移動の帯が折れて見える）
---   奥  : まだ出現していない区間は進捗が負で z が T3DDepth を超えるので、奥の端で切る
---         （切らないと長い Slide の帯がレーンの奥へ飛び出す）
--- 戻り値は手前の点、奥の点の順
function T3DClipBand(ax, az, bx, bz)
  -- 逆走のある TimingGroup では手前と奥が入れ替わることがある。帯は向きを持たないので入れ替えて扱う
  if az > bz then ax, az, bx, bz = bx, bz, ax, az end
  if bz <= 0 or az >= T3DDepth then return nil end   -- 区間ごと消費済み / 区間ごとまだ奥
  if az < 0 then                      -- 手前端だけ通過済み -> z=0 で切る
    local span = bz - az
    local u = 0
    if span > 0 then u = (0 - az) / span end
    ax = ax + (bx - ax) * u
    az = 0
  end
  if bz > T3DDepth then               -- 奥端だけまだ出現していない -> 奥の端で切る
    local span = bz - az
    local u = 1
    if span > 0 then u = (T3DDepth - az) / span end
    bx = ax + (bx - ax) * u
    bz = T3DDepth
  end
  if bz - az < 1 then return nil end  -- 潰れて厚みが無いものは描かない
  return ax, az, bx, bz
end

--- 床ノーツ1つの毎フレームの処理。奥行きの尺度を決めて、描き方（通常 / LegacyMode）に振り分ける
function T3DNoteMove(info, mod, p)
  if mod == nil or p == nil then return end
  local prog = p[0]
  if prog == nil then return end

  -- 床に寝かせるので、コンテナ自体は動かさず頂点を直接投影する
  mod.X = 0
  mod.Y = 0
  mod.Scale = 1
  mod.Alpha = 100

  if not T3DScrollMeasured then T3DMeasureWindow(info, prog) end

  -- ノーツグループごとのスクロール速度。判定の時刻は変えず、見える位置だけを変える
  local speed = T3DSpeed * T3DHsOf(info.group)
  local segs = T3DSegsOf(info)
  local depthK = T3DDepth * speed

  -- TimingGroup のあるグループは、エンジンの p を自前の位置から作ったものに差し替える
  -- （窓の実測は上でエンジンの p から済ませてある）
  local linear = false
  local tg = T3DTgOf(info.group)
  if tg ~= nil then
    p, linear = T3DTgProgress(info, tg, segs, p.Length)
    prog = p[0]
  end

  -- LegacyMode (Beta): 譜面ファイルから登録した Slide はすべて旧 Malody の描き方で描く
  if segs.lg ~= nil then return T3DLegacyDraw(info, mod, p, segs, depthK, tg ~= nil) end
  return T3DDrawNote(info, mod, p, prog, segs, depthK, linear)
end

--- 通常の描き方。頭は判定線を過ぎたら、その時点の Slide の位置に張り付いて横に滑る。
--- prog = p[0]。linear = 逆走のある TimingGroup（奥行きが点の順に増えるとは限らない）
function T3DDrawNote(info, mod, p, prog, segs, depthK, linear)
  local segCount = segs.n
  local headZ = (1 - prog) * depthK

  -- 奥すぎるノーツはここで打ち切る。T3DSpeed で窓を縮めているので、
  -- エンジンが動かしているノーツの大半はまだ見えない位置にいる。
  -- 帯は頭より奥にしか無いので、頭が奥すぎればノーツ全体が見えない
  -- （自分の時間の中で逆走する TimingGroup のノーツは、帯が頭より手前に来ることがあるので
  --   ここでは打ち切らず、点を全部見てから決める）
  if headZ > T3DDepth and not linear then
    T3DHideNote(info, mod)
    return
  end

  local kids = T3DKidsOf(mod, info, segCount)
  local halfW = T3DNoteHalfW(info)

  -- 折れ線の点は 0=頭、1〜lastIdx=各 segment。p が短ければそこまで
  local lastIdx = segCount
  local pLen = p.Length
  if lastIdx > pLen - 1 then lastIdx = pLen - 1 end
  if lastIdx < 0 then lastIdx = 0 end

  -- 見えている帯の範囲だけを扱う。帯 i は点 i-1 と点 i を結び、
  -- 「点 i が判定線より奥(z>0)」かつ「点 i-1 が奥の端より手前(z<T3DDepth)」なら見える。
  --   first = z > 0 になる最初の点 / far = z >= T3DDepth になる最初の点
  local first = 0
  if headZ <= 0 then first = T3DFirstZ(p, 1, lastIdx, depthK, 0, true, linear) end
  local far = T3DFirstZ(p, 1, lastIdx, depthK, T3DDepth, false, linear)
  if linear then far = lastIdx + 1 end   -- 奥へ行った帯が戻ってくることがあるので全部見る
  local bandLo = first
  if bandLo < 1 then bandLo = 1 end
  local bandHi = far
  if bandHi > lastIdx then bandHi = lastIdx end

  -- 使う点だけを「生のZ」で読む。判定線より手前は負になる。
  -- クランプしてしまうと、判定線を跨ぐ区間をどこで切ればいいか分からなくなる
  local px, pz = T3DBufX, T3DBufZ
  px[0] = T3DWorldX(segs.x0)
  pz[0] = headZ
  for i = bandLo - 1, bandHi do
    if i >= 1 then
      local _, sx = T3DSegPoint(segs, i)
      px[i] = T3DWorldX(sx)
      pz[i] = (1 - p[i]) * depthK
    end
  end

  -- 逆走で帯だけが手前に戻ってくるノーツ。頭が奥の端より向こうなら頭は描かず、
  -- 帯もすべて奥の端より向こうならノーツごと消す
  local headFar = false
  if linear and headZ > T3DDepth then
    local near = false
    for i = 1, lastIdx do
      if pz[i] < T3DDepth then near = true break end
    end
    if not near then
      T3DHideNote(info, mod, kids)
      return
    end
    headFar = true
  end

  -- 頭。判定線を過ぎたら、その時点の Slide の位置に張り付いて横に滑る
  local headX = px[0]
  local consumed = false
  if headZ < 0 then
    headZ = 0
    if first >= 1 and first <= lastIdx then
      -- 判定線(z=0)を跨ぐのは帯 first。その交点の x に張り付く
      -- （Slide は横に動くので、通過済みの根元をここまで進めないと折れて見える）
      local az, bz = pz[first - 1], pz[first]
      local span = bz - az
      local u = 0
      if span > 0 then u = (0 - az) / span end
      headX = px[first - 1] + (px[first] - px[first - 1]) * u
    elseif segCount > 0 then
      -- 判定線を跨ぐ区間がもう無い＝帯を全部通過し終わった。
      -- ここで頭を描くと、張り付いていた位置ではなく**元の頭の x** に戻って
      -- 一瞬ちらつく（headX が px[0] のままになるため）
      consumed = true
    end
  end

  -- 判定が済んだ単発ノーツは即座に消す。
  -- エンジンは判定のあとも少しの間 OnNoteMove を呼び続けるので、消さないと
  -- 判定エフェクトが出たあとも判定線に数フレーム張り付いて見える。
  -- 帯を持つ Hold/Slide は頭を判定しても本体が残るので、ここでは消さない（consumed で消える）
  if consumed or (segCount == 0 and T3DJudged[info.nid] ~= nil) then
    T3DHideNote(info, mod, kids)
    return
  end
  T3DHiddenNote[info.nid] = nil

  local broken, dim = T3DNoteBroken(info.nid)
  local headA = T3DAlpha(100 * dim)
  local head = kids.head
  if headFar then
    T3DSetA(head, 0)
    if kids.arrow ~= nil then T3DSetA(kids.arrow, 0) end
  else
    if T3DDrawHead(head, headX, headZ, halfW, broken, headA) and (Fx.rgbPx > 0 or Fx.afterA > 0) then
      -- 画面演出の RGB ずれと残像（T3DSetQuad が覚えた頭の4頂点を写す）
      T3DFxHeadCopies(info.nid, (T3DHeadTex(info.type) == TexWipe) and 'wipe' or 'tap',
        headA, NoteOrder.Head - math.floor(headZ * 0.1), segCount == 0)
    end
    if kids.arrow ~= nil then T3DDrawArrow(kids.arrow, headX, headZ, broken, headA) end
  end

  if segCount == 0 then return end

  -- 帯。見えている帯に、手前から順に帯の Grid を割り当てる（上限 kids.slots を超えた奥の帯は描かない）
  local bandA = T3DAlpha(88 * dim)
  local bandHalf = halfW * 0.78
  local used, slots = 0, kids.slots
  for i = bandLo, bandHi do
    if used >= slots then break end
    local ax, az, bx, bz = T3DClipBand(px[i - 1], pz[i - 1], px[i], pz[i])
    if ax ~= nil and T3DDrawBand(T3DBandOf(kids, used + 1), ax, az, bx, bz, bandHalf, broken, bandA) then
      used = used + 1
      if Fx.rgbPx > 0 then T3DRgbCopy('long', bandA, NoteOrder.Band - math.floor(bz * 0.1)) end
    end
  end
  T3DReleaseBands(kids, used)
end

--- 帯の上の区間 [u0, u1]（0=始点, 1=終点）のうち、奥行き z（始点 za・終点 zb の間を直線）が lo〜hi に入る部分。無ければ nil
function T3DLegacyClipU(za, zb, u0, u1, lo, hi)
  if u1 <= u0 then return nil end
  local dz = zb - za
  if dz == 0 then
    if za >= lo and za <= hi then return u0, u1 end
    return nil
  end
  local ua, ub = (lo - za) / dz, (hi - za) / dz
  if ua > ub then ua, ub = ub, ua end
  if ua > u0 then u0 = ua end
  if ub < u1 then u1 = ub end
  if u1 <= u0 then return nil end
  return u0, u1
end

--- LegacyMode の各点（元の順）の奥行きを T3DLegacy.bufZ に入れる。
--- 譜面の effect から求めた位置があれば、それを使う（C# 側の p を読むのは頭と最後の点の2つだけ）。
--- 頭はエンジンの p をそのまま使い、ほかの点は頭からの位置の差で出す（スキンの時刻とエンジンの時刻のずれが効かない）。
--- 窓の長さ W は、頭と最後の点の p の差から求める。予想した最後の点の p がエンジンとずれたら
--- （effect の解釈が違う譜面）、以後は p を全部読む描き方にする
function T3DLegacyDepths(info, p, segs, depthK, useTg)
  local lg = segs.lg
  local n = lg.n
  local pz = T3DLegacy.bufZ
  local P = lg.P
  local usePos = (P ~= nil) and (not useTg) and (not T3DLegacy.posBad) and (p.Length - 1 >= lg.n)
  if usePos then
    if lg.Pend == nil then
      lg.Pend = T3DTgPos(T3DLegacy.pos, T3DSegPoint(segs, lg.n))   -- エンジンの最後の点（時刻順で一番遅い点）
    end
    local q0, qe = 1 - p[0], 1 - p[lg.n]
    local span = lg.Pend - P[0]
    local W = T3DLegacy.W
    if W == nil and math.abs(span) > 200 and math.abs(qe - q0) > 1e-6 then
      W = span / (qe - q0)
      if W > 200 and W < 60000 then
        T3DLegacy.W = W
        print(string.format('[T3D] LegacySlide: 窓=%.0fms（譜面の effect から位置を計算する）', W))
      else
        W = nil
      end
    end
    if W == nil then
      usePos = false
    elseif math.abs(span) > 200 and math.abs((q0 + span / W) - qe) > 0.005 then
      T3DLegacy.posBad = true
      usePos = false
      print(string.format('[T3D] LegacySlide: 計算した位置がエンジンと合わない（nid=%d 予想=%.4f エンジン=%.4f）。p を読む描き方に戻す',
        info.nid, q0 + span / W, qe))
    else
      local k = depthK / W
      local base = q0 * depthK - P[0] * k
      for i = 0, n do pz[i] = base + P[i] * k end
    end
  end
  if not usePos then
    local j = T3DLegacyMapJ(lg)
    local pLast = p.Length - 1
    for i = 0, n do
      local ji = j[i]
      if ji <= pLast then pz[i] = (1 - p[ji]) * depthK else pz[i] = T3DDepth * 10 end
    end
  end
  return pz
end

--- LegacyMode (Beta) の描画。点は譜面ファイルの元の順（lg）、各点の奥行きはエンジンの p を時刻で引いたもの。
---   帯 i（点 i-1 -> i）は、時刻が戻る辺なら描かない。終わりの点の時刻を過ぎたら消える。
---   始まりの点の時刻が来た帯は判定線(z=0)より奥だけ、まだの帯は T3DLegacy.NearZ（画面の下端より外）まで描く。
---   頭は最初の区間（判定のある部分）が終わるまで。判定線を過ぎたら最初の区間の上に張り付く
function T3DLegacyDraw(info, mod, p, segs, depthK, useTg)
  local lg = segs.lg
  local n = lg.n
  local now = Game:Time()
  local kids = T3DKidsOf(mod, info, segs.n)

  if now >= lg.tEnd then
    T3DHideNote(info, mod, kids)
    return
  end
  T3DHiddenNote[info.nid] = nil

  local px, pz = lg.wx, T3DLegacyDepths(info, p, segs, depthK, useTg)
  local broken, dim = T3DNoteBroken(info.nid)
  local halfW = T3DNoteHalfW(info)

  -- 頭
  local headZ, headX = pz[0], px[0]
  local showHead = true
  if headZ > T3DDepth then
    showHead = false
  elseif headZ < 0 then
    if now < lg.t[lg.firstN] then
      headZ = 0
      headX = T3DWorldX(T3DSlideXAt(info, now))
    else
      showHead = false
    end
  end
  if kids.arrow ~= nil then T3DSetA(kids.arrow, 0) end
  if not (showHead and T3DDrawHead(kids.head, headX, headZ, halfW, broken, T3DAlpha(100 * dim))) then
    T3DSetA(kids.head, 0)
  end

  -- 帯。見えている帯を集め、帯の Grid を割り当てる。上限 kids.slots を超えたら手前のものを優先する
  -- （元の順は奥行きの順ではないので、超えたときだけ奥行きで並べる）
  local nearZ = T3DLegacy.NearZ
  local cand = T3DLegacy.cand
  local nc = 0
  for i = 1, n do
    local ta, tb = lg.t[i - 1], lg.t[i]
    if tb > ta and now < tb then
      local az, bz = pz[i - 1], pz[i]
      -- 始まりの時刻が来た帯（今判定している帯）は判定線より奥だけ描く（時刻を過ぎた部分は判定線を越えたら消える）。
      -- まだ始まっていない帯は、逆走などで判定線より手前に来ても描く
      local lo = nearZ
      if now >= ta then lo = 0 end
      local u0, u1 = T3DLegacyClipU(az, bz, 0, 1, lo, T3DDepth)
      if u0 ~= nil then
        local ax, bx = px[i - 1], px[i]
        local x0, z0 = ax + (bx - ax) * u0, az + (bz - az) * u0
        local x1, z1 = ax + (bx - ax) * u1, az + (bz - az) * u1
        if z0 > z1 then x0, z0, x1, z1 = x1, z1, x0, z0 end
        if z1 - z0 >= 1 then
          nc = nc + 1
          local e = cand[nc]
          if e == nil then e = {} cand[nc] = e end
          e[1], e[2], e[3], e[4] = x0, z0, x1, z1
        end
      end
    end
  end
  local slots = kids.slots
  if nc > slots then
    for i = nc + 1, #cand do cand[i] = nil end
    table.sort(cand, function(a, b) return a[2] < b[2] end)
    nc = slots
  end
  local bandA = T3DAlpha(88 * dim)
  local bandHalf = halfW * 0.78
  local used = 0
  for c = 1, nc do
    local e = cand[c]
    if T3DDrawBand(T3DBandOf(kids, used + 1), e[1], e[2], e[3], e[4], bandHalf, broken, bandA) then
      used = used + 1
    end
  end
  T3DReleaseBands(kids, used)
end

--------------------------------------------------------------------------------
-- 仮想ノーツ（小節線・空中要素の位置をエンジンに出させる目印）
--------------------------------------------------------------------------------

--- 仮想ノーツを置く時刻を1つ積む（同じ時刻はまとめる）。keys は丸めた時刻の一覧
function T3DVirtWant(keys, t)
  local key = math.floor(t + 0.5)
  if T3DVirt.byT[key] == nil then
    T3DVirt.byT[key] = { t = key }
    keys[#keys + 1] = key
  end
end

--- 小節線・空中要素の時刻に仮想ノーツを置く（OnProcessNote で1回）。
--- エンジンはリトライのたびに OnProcessNote を呼び直し、前の仮想ノーツを捨てる（TestCode41 で確認）。
--- 記録を残したままだと T3DVirtWant が「置き済み」とみなして1個も置かず、空中要素などが一瞬で通り過ぎる。
--- なので毎回、記録と小節線の一覧を作り直す
function T3DAddVirtuals()
  local keys = {}
  T3DVirt.byT = {}
  T3DVirt.measure = {}
  T3DVirt.rate = 0

  -- 曲の終わり（最後のノーツ）までの小節線
  local last = 0
  local cnt = Chart:NoteCount()
  for i = 0, cnt - 1 do
    local n = Chart:NoteAt(i)
    if n ~= nil then
      if n.time > last then last = n.time end
      if n.endtime ~= nil and n.endtime > last then last = n.endtime end
    end
  end
  for _, r in ipairs(T3DAirSlides) do if r.e > last then last = r.e end end
  for _, r in ipairs(T3DAirTaps) do if r.time > last then last = r.time end end
  for _, r in ipairs(Trace.lines) do if r.e > last then last = r.e end end
  for _, r in ipairs(Trace.guides) do if r.e > last then last = r.e end end

  -- 小節線は設定で隠していても置く（リトライで表示に戻したとき、置いていないと譜面の scroll に乗らない）。
  -- 最後の要素より後ろには置かない。エンジンは仮想ノーツも含めた最後のノーツを過ぎるまでプレイを終えず
  -- （それまでは結果画面へ行けない）、時計は音源が終わって約 2 秒で止まるので、
  -- 後ろに置くと音源の短い譜面で結果画面へ行けなくなる（2026-10-21 実機で確認。以前は最後の要素の 4 秒後まで置いていた）
  local g = T3DVirt.measureG
  if T3DBuilt.Measure and MeasureBeats > 0 and T3DBpmTable ~= nil and T3DTgOf(g) == nil then
    local k = math.ceil(-MeasureStartBeat / MeasureBeats)   -- 曲頭(拍0)より後の最初の1本
    while true do
      local t = T3DTimeAtBeat(MeasureStartBeat + k * MeasureBeats)
      if t > last then break end
      T3DVirt.measure[#T3DVirt.measure + 1] = t
      T3DVirtWant(keys, t)
      k = k + 1
    end
  end

  -- 空中要素（timinggroup のあるグループを指定したものは自前で計算するので要らない）
  for _, r in ipairs(T3DAirSlides) do
    if T3DTgOf(r.g) == nil then
      for i = 0, AirConf.SlideSamples do
        T3DVirtWant(keys, r.s + (r.e - r.s) * (i / AirConf.SlideSamples))
      end
    end
  end
  for _, r in ipairs(T3DAirTaps) do
    if T3DTgOf(r.g) == nil then T3DVirtWant(keys, r.time) end
  end
  -- トレースは区間の両端だけ（途中の点は T3DTraceDepths が今の scroll で埋める）。
  -- 分割した点ごとに置くと、飾りの多い譜面で仮想ノーツが数千になり FPS が落ちた
  for _, list in ipairs({ Trace.lines, Trace.guides }) do
    for _, r in ipairs(list) do
      if T3DTgOf(r.g) == nil then
        T3DVirtWant(keys, r.s)
        T3DVirtWant(keys, r.e)
      end
    end
  end

  table.sort(keys)
  for _, key in ipairs(keys) do
    Note:AddVirtual({ type = T3DVirt.base, time = key, x = 128, width = 1, group = 0 })
  end
  T3DVirt.count = #keys
  T3DVirt.ok = true
  print(string.format('[T3D] 仮想ノーツ: %d 個（小節線 %d 本、空中要素 AirSlide %d 本・AirTap %d 個、trace %d・guide %d 区間）',
    #keys, #T3DVirt.measure, #T3DAirSlides, #T3DAirTaps, #Trace.lines, #Trace.guides))
end

--- 仮想ノーツの OnNoteMove。1 - p を覚える
function T3DVirtMove(info, p)
  local rec = T3DVirt.byT[info.time]
  if rec == nil then return end
  local now = Game:Time()
  local rem = 1 - p[0]
  if rec.at ~= nil and now > rec.at and now - rec.at < 100 then
    -- jump の瞬間は rem が跳ぶので、速さとしてはありえない値になる。そういうフレームは使わない
    -- （scroll 20 倍を上限とみなす）。Update は OnNoteMove より先に呼ばれるので、この速さで1フレーム分進めて使う
    local r = (rec.rem - rem) / (now - rec.at)
    local lim = 20 / math.max(T3DScrollWindow, 1)
    if r > -lim and r < lim then T3DVirt.rate = r end
  end
  rec.rem, rec.at = rem, now
end

--------------------------------------------------------------------------------
-- 配点
--------------------------------------------------------------------------------
--- ノーツ総数が確定したので、1ノーツあたりの配点を決める。
--- 空中要素（AirSlide の区間・AirTap）もそれぞれ1ノーツとして数える。
--- 空中要素は Init で読み込み済み（呼び出し順は Init -> OnProcessNote）
function OnProcessNote()
  if T3DBuilt.Measure or T3D.Air or Trace.on then T3DSafe('仮想ノーツ', T3DAddVirtuals) end
  local floorCount = 0
  local ok, res = pcall(function() return Chart:ChartInfo('note') end)
  if ok then floorCount = tonumber(res) or 0 end

  -- 直角の Lift は判定を持たないので配点にも数えない
  local airCount = 0
  for _, r in ipairs(T3DAirSlides) do
    if not r.instant then airCount = airCount + 1 end
  end

  local cnt = floorCount + airCount + #T3DAirTaps
  T3DScore.noteCount = cnt
  if cnt > 0 then
    T3DScore.perNote = T3DScore.total / cnt
  end
  print(string.format('[T3D] 配点: 床=%d AirSlide区間=%d(うち直角%d除く) AirTap=%d -> 1ノーツ %.2f点',
    floorCount, airCount, #T3DAirSlides - airCount, #T3DAirTaps, T3DScore.perNote))
end

print('[T3D] chunk end')

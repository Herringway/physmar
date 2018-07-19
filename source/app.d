import std.stdio;
import std.algorithm: canFind, count, filter, min, remove;
import std.range;
import std.conv : text;
import std.datetime : Clock;
import std.format : format;
import std.math: fmod, PI;
import gfm.math, gfm.sdl2;
import std.experimental.logger;
import std.typecons;

import dchip.all;

// Compile-time constants
enum gameArea  = vec2i(800, 600);
enum gameAreaF = vec2f(800.0f, 600.0f);
enum horizontalMovementVelocity = vec2f(5.0f, 0.0f);
enum jumpVelocity = vec2f(0.0f, -50.0f);
enum friction = 0.98f;
enum tileMass = 10.0f;
enum marioMass = 40000.0f;

struct GamePlatform {
	SDL2 sdl2;
	SDL2Window window;
	SDL2Renderer renderer;
	version(ttf) {
		SDLTTF sdlttf;
		SDLFont font;
	}

	SDL2Texture[] cachedBallTextures;
	SDL2Surface[] cachedBallSurfaces;

	// Disable the default constructor
	@disable this();

	this(Logger log) {
		sdl2 = new SDL2(log, SharedLibVersion(2, 0, 0));
		version(ttf) {
			sdlttf = new SDLTTF(sdl2);
		}

		sdl2.subSystemInit(SDL_INIT_VIDEO);
		sdl2.subSystemInit(SDL_INIT_EVENTS);
		sdl2.subSystemInit(SDL_INIT_AUDIO);

		SDL_ShowCursor(SDL_DISABLE);

		const windowFlags = SDL_WINDOW_SHOWN | SDL_WINDOW_INPUT_FOCUS | SDL_WINDOW_MOUSE_FOCUS;
		window = new SDL2Window(sdl2, SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, gameArea.x, gameArea.y, windowFlags);
		renderer = new SDL2Renderer(window, SDL_RENDERER_ACCELERATED);

		import std.file: thisExePath;
		import std.path: buildPath, dirName;
		version(ttf) {
			font = new SDLFont(sdlttf, thisExePath.dirName.buildPath("DroidSans.ttf"), 20);
		}
	}
	~this() {
		foreach (i; 0..cachedBallSurfaces.length) {
			destroy(cachedBallSurfaces[i]);
		}
		foreach (i; 0..cachedBallTextures.length) {
			destroy(cachedBallTextures[i]);
		}
		version(ttf) {
			destroy(font);
			destroy(sdlttf);
		}
		destroy(renderer);
		destroy(window);
		destroy(sdl2);
	}
	void drawBackground() {
		renderer.setColor(6, 107, 140, 255);
		renderer.clear();
	}
	void finalizeFrame() {
		renderer.present();
	}
	void drawPlayer(const vec2f position) {
		renderer.setColor(231, 0, 0, 255);
		renderer.fillRect(cast(int)position.x-8, cast(int)position.y-12, 16, 24);

	}
	void drawTile(const vec2f position) {
		renderer.setColor(231, 90, 16, 255);
		renderer.fillRect(cast(int)position.x, cast(int)position.y, 16, 16);
	}
}
struct Entity {
    enum Type: ubyte {
        player,
        tile
    }

    ///
    Type type;
    ///
    vec2f pos;
}

struct GameState {
	public Entity[] tiles;
	public Entity player;
	cpSpace* space;
	cpBody*[] physEntities;
	cpBody* playerEntity;

	void init(const Stage stage) {
		space = cpSpaceNew();
		space.sleepTimeThreshold = 0.5f;
		space.iterations = 10;
		space.gravity = cpv(0, 100.0);
		foreach (int y, row; stage.tiles) {
			foreach (int x, tile; row) {
				if (tile != Tile.air) {
					addTile(tile, vec2i((x-25)*16, y*16));
				}
			}
		}
		addPlayer(vec2i(0, 2));
	}
	void addTile(Tile tile, vec2i coords) {
		cpVect[4] tris = [
			cpv(0,0),
			cpv(0, 16),
			cpv(16, 16),
			cpv(16, 0)
		];
		cpFloat mass = tileMass;


		cpShape* tileShape;
		if (tile == Tile.boundary) {
			tileShape = cpSegmentShapeNew(space.staticBody, cpv(coords.x, coords.y), cpv(coords.x+16, coords.y+16), 0.0f);
			tileShape.e = 1.0f;
			tileShape.u = 1.0f;
			tileShape.cpShapeSetElasticity(cpFloat(0.0f));
		} else {
			auto tileBody = cpBodyNew(mass, cpMomentForPoly(mass, tris.length, tris.ptr, cpvzero));
			cpSpaceAddBody(space, tileBody);
			tileBody.p = cpv(coords.x, coords.y);
			tileShape = cpPolyShapeNew(tileBody, tris.length, tris.ptr, cpv(0, 0));
			tileShape.e = 0.0f;
			tileShape.u = 0.9f;
			tileShape.cpShapeSetElasticity(cpFloat(0.2f));
			physEntities ~= tileBody;
			tiles ~= Entity(Entity.Type.tile, physToRendererCoords(vec2f(tileBody.p.x, tileBody.p.y)));
		}

		cpSpaceAddShape(space, tileShape);

	}
	void addPlayer(vec2i coords) {
		cpVect[4] tris = [
			cpv(0,0),
			cpv(0, 24),
			cpv(16, 24),
			cpv(16, 0)
		];
		cpFloat mass = marioMass;

		auto tileBody = cpBodyNew(mass, cpMomentForPoly(mass, tris.length, tris.ptr, cpvzero));
		cpSpaceAddBody(space, tileBody);
		tileBody.p = cpv(coords.x, coords.y);
		auto tileShape = cpPolyShapeNew(tileBody, tris.length, tris.ptr, cpv(0, 0));
		tileShape.e = 0.0f;
		tileShape.u = 0.9f;
		tileShape.cpShapeSetElasticity(cpFloat(0.2f));

		cpSpaceAddShape(space, tileShape);
		playerEntity = tileBody;
		player = Entity(Entity.Type.player, physToRendererCoords(vec2f(tileBody.p.x, tileBody.p.y)));

	}

	void step() {
		cpSpaceStep(space, 1.0/60.0);
		foreach (i, ref entity; physEntities) {
			tiles[i].pos = physToRendererCoords(vec2f(entity.p.x, entity.p.y));
		}
		player.pos = physToRendererCoords(vec2f(playerEntity.p.x, playerEntity.p.y));
	}

	void moveLeft() {
		assert(playerEntity);
		enum negatedHorizontalVelocity = horizontalMovementVelocity * vec2f(-1.0, 0.0);
		playerEntity.v = cpv(playerEntity.v.x + negatedHorizontalVelocity.x, playerEntity.v.y + negatedHorizontalVelocity.y);
	}

	void moveRight() {
		assert(playerEntity);
		playerEntity.v = cpv(playerEntity.v.x + horizontalMovementVelocity.x, playerEntity.v.y + horizontalMovementVelocity.y);
	}

	void jump() {
		assert(playerEntity);
		playerEntity.v = cpv(jumpVelocity.x, jumpVelocity.y);
	}
}

bool handleInput(ref GameState game) {
	SDL_Event event;
	while(SDL_PollEvent(&event)) {
		if (event.type == SDL_QUIT) {
			return false;
		}

		// Ignore repeated events when the key is being held
		if (event.type == SDL_KEYDOWN && !event.key.repeat) {
			switch(event.key.keysym.scancode) {
				case SDL_SCANCODE_SPACE:
					game.jump();
					break;
				default: break;
			}
		}
	}

	int keysLen;
	// C API function, returns a pointer.
	const ubyte* keysPtr = SDL_GetKeyboardState(&keysLen);
	// Bounded slice for safety
	const keys = keysPtr[0 .. keysLen];

	if (keys[SDL_SCANCODE_LEFT])  {
		game.moveLeft();
	}
	if (keys[SDL_SCANCODE_RIGHT]) {
		game.moveRight();
	}

	return true;
}

void main() {
	import core.time;
	auto log = new FileLogger("physmar.log");
	auto platform = GamePlatform(log);

	auto prevFPSTime = Clock.currTime();
	auto prevForceTime = Clock.currTime();
	auto prevDrawTime = Clock.currTime();
	uint frames = 0;

	auto game = GameState();

	static immutable stage = loadStage(import("1-1.pmr"));

	game.init(stage);

	while(true) {
		const currTime = Clock.currTime();

		const timeSinceLastFPSUpdate = currTime - prevFPSTime;
		const timeSinceLastFrame = currTime - prevDrawTime;
		debug(showfps) {
			if (timeSinceLastFPSUpdate > 100.msecs) {
				const float fps = cast(float)frames / (cast(float)timeSinceLastFPSUpdate.total!"hnsecs" / 1.seconds.total!"hnsecs");
				platform.window.setTitle(format!"PhysMar: %.2f FPS"(fps));
				frames = 0;
				prevFPSTime = currTime;
			}
		}
		if (timeSinceLastFrame >= 166666.hnsecs) {
			++frames;
			game.step();

			if (!handleInput(game)) {
				return;
			}

			platform.drawBackground();
			foreach (tile; game.tiles.chain(only(game.player))) {
				final switch (tile.type) {
					case Entity.Type.player:
						platform.drawPlayer(tile.pos);
						break;
					case Entity.Type.tile:
						platform.drawTile(tile.pos);
						break;
				}
			}
			platform.finalizeFrame();
			prevDrawTime = currTime;
		}
	}
}

enum Tile {
	air,
	pipe,
	groundBlock,
	solidBlock,
	brickBlock,
	questionBlock,
	boundary,
	flagpole,
	flag,
	castle
}
struct Stage {
	Tile[][] tiles;
}

auto loadStage(string data) {
	import std.string : lineSplitter;
	Stage output;
	auto lineByLine = data.lineSplitter();
	foreach (line; lineByLine) {
		Tile[] row;
		foreach (chr; line) {
			switch (chr) {
				case ' ': row ~= Tile.air; break;
				case '(': row ~= Tile.pipe; break;
				case ')': row ~= Tile.pipe; break;
				case '#': row ~= Tile.groundBlock; break;
				case '%': row ~= Tile.solidBlock; break;
				case '=': row ~= Tile.brickBlock; break;
				case '?': row ~= Tile.questionBlock; break;
				case '-': row ~= Tile.boundary; break;
				case '|': row ~= Tile.flagpole; break;
				case '<': row ~= Tile.flag; break;
				case '&': row ~= Tile.castle; break;
				default: assert(0, "Unknown block type "~chr);
			}
		}
		output.tiles ~= row;
	}
	return output;
}

vec2f physToRendererCoords(const vec2f input) {
	vec2f output;
	output = input + gameAreaF/vec2f(2.0, 2.0);
	return output;
}
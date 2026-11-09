// Offline flash meter: render a preset for N s with synthetic kick+bass audio at real time,
// sample mean luminance (and 8x8 grid) per frame. Prints per-frame lum to stdout.
#include <SDL2/SDL.h>
#include <OpenGL/gl3.h>
#include <projectM-4/projectM.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char**argv){
  if(argc<3){fprintf(stderr,"usage: flash preset.milk seconds [show]\n");return 2;}
  double secs=atof(argv[2]); int show=argc>3;
  SDL_Init(SDL_INIT_VIDEO);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION,3);SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION,3);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,SDL_GL_CONTEXT_PROFILE_CORE);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS,SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG);
  int W=320,H=180;
  SDL_Window*w=SDL_CreateWindow("flash",0,0,W,H,SDL_WINDOW_OPENGL|(show?0:SDL_WINDOW_HIDDEN));
  if(!w){fprintf(stderr,"win %s\n",SDL_GetError());return 1;}
  SDL_GLContext c=SDL_GL_CreateContext(w); if(!c){fprintf(stderr,"ctx %s\n",SDL_GetError());return 1;}
  SDL_GL_SetSwapInterval(0);
  int fw,fh; SDL_GL_GetDrawableSize(w,&fw,&fh);
  projectm_handle pm=projectm_create(); if(!pm){fprintf(stderr,"pm\n");return 1;}
  projectm_set_window_size(pm,fw,fh); projectm_set_fps(pm,30);
  projectm_set_preset_duration(pm,1e6); projectm_set_preset_locked(pm,true);
  projectm_load_preset_file(pm,argv[1],false);
  int frames=(int)(secs*30); float buf[1470*2]; double t=0; unsigned char*px=malloc(fw*fh*4);
  Uint64 f0=SDL_GetPerformanceFrequency(), start=SDL_GetPerformanceCounter();
  for(int f=0;f<frames;f++){
    SDL_Event e; while(SDL_PollEvent(&e)){}
    for(int i=0;i<1470;i++){ // 44.1k/30
      double ph=fmod(t,0.5); // 120 bpm kick
      double kick=exp(-ph*18)*sin(2*M_PI*(50+120*exp(-ph*30))*ph);
      double bass=0.35*sin(2*M_PI*55*t)*(fmod(t,1.0)<0.5?1:0.6);
      double hat=0.08*((rand()/(double)RAND_MAX)-0.5)*(fmod(t,0.25)<0.03);
      double mid=0.15*sin(2*M_PI*440*t)*sin(2*M_PI*0.3*t);
      float s=(float)(0.6*kick+bass+hat+mid); buf[2*i]=s; buf[2*i+1]=s; t+=1/44100.0;}
    projectm_pcm_add_float(pm,buf,1470,PROJECTM_STEREO);
    glBindFramebuffer(GL_FRAMEBUFFER,0); glViewport(0,0,fw,fh); glClearColor(0,0,0,1); glClear(GL_COLOR_BUFFER_BIT);
    projectm_opengl_render_frame(pm);
    glReadPixels(0,0,fw,fh,GL_RGBA,GL_UNSIGNED_BYTE,px);
    double L=0; double G[16]={0};
    for(int y=0;y<fh;y++)for(int x=0;x<fw;x++){unsigned char*p=px+4*(y*fw+x);
      double l=(0.2126*p[0]+0.7152*p[1]+0.0722*p[2])/255.0; L+=l; G[(y*4/fh)*4+(x*4/fw)]+=l;}
    L/=fw*fh; printf("%d %.4f",f,L); for(int g=0;g<16;g++)printf(" %.3f",G[g]/(fw*fh/16.0)); printf("\n");
    SDL_GL_SwapWindow(w);
    double target=(f+1)/30.0, now=(SDL_GetPerformanceCounter()-start)/(double)f0;
    if(target>now) SDL_Delay((Uint32)((target-now)*1000));
  }
  projectm_destroy(pm); SDL_Quit(); return 0;}

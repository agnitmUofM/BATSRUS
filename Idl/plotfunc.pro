;  Copyright (C) 2002 Regents of the University of Michigan, 
;  portions used with permission 
;  For more information, see http://csem.engin.umich.edu/tools/swmf
;===========================================================================
;    Written by G. Toth for the Versatile Advection Code
;
;    Use the x and w in the memory read by "animate".
;    plot one or more functions of w using different plotting routines. 
;    The functions are defined in the "Idl/funcdef.pro" file.
;
;    For generalized coordinates the variables are interpolated from the 
;    irregular grid onto a regular one.
;
;    A subset can be cut from the grid by using the "cut" index array, e.g.:
;    cut=grid(10:30,*), where "grid" contains the full index array.
;    for the regular grid. The grid array is only defined after animate ran.
;
;    Usage:
;
; .r plotfunc
;
;    Output can be directed to a color PostScript file like this:
;
; set_plot,'PS'
; device,filename='myfile.ps',xsize=24,ysize=18,/landscape,/color,bits=8
; loadct
; .r plotfunc
; device,/close
; set_plot,'X'
;
;    On a non-color printer omit the '/color,bits=8' parameters and the
;    'loadct' command.
;
;    For a non-color PORTRAIT style printout use
;
; device,filename='myfile.ps',xsize=18,ysize=24,yoffset=3
;
;===========================================================================

common getpict_param

if not keyword_set(nfile) then begin
   print,'No file has been read yet, run getpict or animate!'
   return
endif

if nfile gt 1 then begin
      print,'More than one files were read...'
      print,'Probably w is from file ',filenames(nfile-1)
      nfile=1
   endif

   print,'======= CURRENT PLOTTING PARAMETERS ================'
   print,'ax,az=',ax,',',az,', contourlevel=',contourlevel,$
         ', velvector=',velvector,', velspeed (0..5)=',velspeed,$
        FORMAT='(a,i4,a,i3,a,i3,a,i4,a,i2)'
   print,'multiplot=',multiplot
   print,'axistype (coord/cells)=',axistype,', fixaspect= ',fixaspect,$
            FORMAT='(a,a,a,i1)'
   print,'bottomline=',bottomline,', headerline=',headerline,$
        FORMAT='(a,i1,a,i1)'

   if keyword_set(cut) then help,cut
   if keyword_set(velpos) then help,velpos
   velpos0=velpos

   ; Read plotting and transforming parameters

   print,'======= PLOTTING PARAMETERS ========================='
   print,'wnames                     =',wnames
   read_plot_param

   help,nx

   read_transform_param

   ; ifile=0, also pass dotransform and doask
   do_transform

   print,'======= DETERMINE PLOTTING RANGES ==================='

   read_limits

   if noautorange eq 0 then begin
      get_limits,1

      print
      for ifunc=0,nfunc-1 do $
      print,'Min and max value for ',funcs(ifunc),':',fmin(ifunc),fmax(ifunc)
   endif

   ;===== DO PLOTTING IN MULTIX * MULTIY MULTIPLE WINDOWS

   if keyword_set(multiplot) then begin
      if n_elements(multiplot) eq 1 then begin
         if multiplot gt 0 then       !p.multi=[0,multiplot,1 ,0,1] $
         else if multiplot eq -1 then !p.multi=[0,1,nplot     ,0,1] $
         else                         !p.multi=[0,1,-multiplot,0,1]
      endif else if n_elements(multiplot) eq 5 then $
         !p.multi = multiplot $
      else $
         !p.multi=[0,multiplot(0),multiplot(1),0,multiplot(2)]
      multix=!p.multi(1)
      multiy=!p.multi(2)
   endif else begin
      multix=long(sqrt(nplot-1)+1)
      multiy=long((nplot-1)/multix+1)
      !p.multi=[0,multix,multiy,0,0]
   endelse

   if not noerase then erase

   if velrandom then velpos=0

   if !d.name eq 'X' and !d.window ge 0 then wshow

   plot_func
   
   putbottom,1,1,0,0,bottomline,nx,it,time
   putheader,1,1,0,0,headerline,headline,nx

   print
   !p.multi=0
   !p.title=''
   !x.title=''
   !y.title=''
   !z.title=''
   ; Restore velpos array
   velpos=velpos0 & velpos0=0

end

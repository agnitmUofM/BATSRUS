; This code is a copyright protected software (c) 2002- University of Michigan 
;
; Definitions and/or default values for global variables

; Confirmation for set parameters
doask=0

; Do not erase before new plot
noerase=0

; Aspect ratio: 0 - not fixed (fill screen), 
;               1 - use coordinates, other values - set aspect ratio
fixaspect=1

; Array subtracted from w during animation
wsubtract=0

; take time derivative of w during animation if timediff=1
timediff=0

; Keep original size of fits image
noresize=0

; Parameters for .r getpict
filename='' ; space separated string of filenames. May contain *, []
npict=0     ; index of snapshot to be read

; Parameters for .r plotfunc
func=''           ; space separated list of functions to be plotted
plotmode='plot'     ; space separated list of plot modes
plottitle='default' ; semicolon separated list of titles
plottitles_file=''  ; array of plottitle strings per file

timetitle=''     ; set to format string to plot time as title for time series
timetitleunit=0  ; set to number of seconds in time unit
timetitlestart=0 ; set to initial time to be subtracted (in above units)

autorange='y'    ; function ranges fmin and fmax set automatically or by hand
axistype='coord' ; 'cells' or 'coord'

; multiplot=0 gives the default number of subplots depending on nfile,nfunc
; multiplot=[3,2,0] defines 3 by 2 subplots filled up in vertical order
; multiplot=[2,4,1] defines 2 by 4 subplots filled up in horizontal order
multiplot=0

; Number of info items on bottom and header lines
headerline=0
bottomline=3

; Parameters for surface and shade_surf
ax=30
az=30

; Number of contour levels for contour and contfill
contourlevel=30

; Parameters for the vector plots and stream lines
velvector=200 ; number of vectors/stream lines per plot
velpos   =0   ; 2 x velvector array with start positions 
velrandom=0   ; if 1 use random start positions for each frame of animation
velspeed =5   ; speed of moving vectors during animation

; Animation parameters for the movie
firstpict=1   ; a scalar or array (per file) of the index of first frame
dpict=1       ; a scalar or array (per file) of distance between frames
npictmax=500  ; maximum number of frames in an animation

; Parameters for saving the movie into ps/png/tiff/bmp/jpeg files
savemovie='n'     ; 'ps', 'png', 'tiff' ...

; Parameters for .r slice
firstslice=1      ; index of first slice
dslice=1          ; stride between slices
nslicemax=500     ; maximum number of slices shown
slicedir=0        ; 
dyslicelabel=0.98 ; position of bottom label (?)

; Transformation parameters for irregular grids 
dotransform='n'   ; do transform with .r plotfunc?
transform='n'     ; transformation 'none', 'regular', 'my', 'polar', 'unpolar'
nxreg=[0,0]       ; size of transformed grid
xreglimits=0      ; limits of transformed grid [xmin, ymin, xmax, ymax]
symmtri=0         ; use symmetric triangulation during transformation?

; Define the variables that are vectors for grid transformation
nvector=0 ; number of vector variables
vectors=0 ; index of first components of vector variables

; Arrays for cutting out part of the grid
grid=0    ; index array for the whole grid
cut=0     ; index array for the cut
rcut=-1.0 ; Radius of cutting out inner part

; Parameters for getlog
logfilename='' ; space separated string of filenames. May contain *, []

; Parameters for plotlog
logfunc=''   ; space separated list of log variables in wlogname(s)
title=0      ; set to a string with the title
xtitle=0     ; set to a string with the time title
ytitles=0    ; set to a string array with the function names
timeunit='h' ; set to '1' (unitless), 's' (second), 'm' (minute), 'h' (hour) 
	     ;        'millisec', 'microsec', 'ns' (nanosec)
xrange=0     ; set to a [min,max] array for the time range
yranges=0    ; set to a [[min1,max1], [min2,max2] ...] for function ranges
colors=255   ; set to an array with colors for each function
linestyles=0 ; set to an array with line styles for each function
symbols=0    ; set to an array with symbols for each function
smooths=0    ; set to an array with smoothing width for each logfile
dofft=0      ; set to 1 to do an FFT transform on the functions
legends=''   ; legends for the lines, defaults are logfilenames
legendpos=0  ; position for the legends: [xmin, xmax, ymin, ymax]

; System variables that can get corrupted if an animation is interrupted
!x.tickname=strarr(60)
!y.tickname=strarr(60)

; parameters passed to plot_func through common blocks
; Distance betwen plots measured in character size
common plot_param,plot_spacex,plot_spacey
plot_spacex=3
plot_spacey=3

; calculate running max or mean of functions during animation
common plot_store, nplotstore, iplotstore, nfilestore, ifilestore, $
       plotstore, timestore
nplotstore = 0
iplotstore = 0
nfilestore = 1
ifilestore = 0
plotstore  = 0
timestore  = 0

; Distance betwen log plots measured in character size
common log_param,log_spacex,log_spacey
log_spacex=5
log_spacey=5

; Some useful constants in SI units
common phys_const, kbSI, mpSI, mu0SI, eSI, ReSI, RsSI, AuSI, cSI, e0SI

kbSI   = 1.3807d-23      ; Boltzmann constant
mpSI   = 1.6726d-27      ; proton mass
mu0SI  = 4*!dpi*1d-7     ; vacuum permeability
eSI    = 1.602d-19       ; elementary charge
ReSI   = 6378d3          ; radius of Earth
RsSI   = 6.96d8          ; radius of Sun
AuSI   = 1.4959787d11    ; astronomical unit
cSI    = 2.9979d8        ; speed of light
e0SI   = 1/(mu0SI*cSI^2) ; vacuum permettivity 

; Physical unit names and values in SI units
common phys_units, $
       fixunits, typeunit, xSI, tSI, rhoSI, uSI, pSI, bSI, jSI, Mi, Me

fixunits   = 0             ; If 0, the units get overwritten 
	     		   ; based on each file read, otherwise fixed
typeunit   = 'NORMALIZED'  ; 'SI', 'NORMALIZED', 'PIC', 'PLANETARY', 'SOLAR'
xSI        = 1.0           ; distance unit in SI
tSI        = 1.0           ; time unit in SI
rhoSI      = 1.0           ; density unit in SI
uSI        = 1.0           ; velocity unit in SI
pSI        = 1.0           ; pressure unit in SI
bSI        = sqrt(mu0SI)   ; magnetic unit in SI
jSI        = 1/sqrt(mu0SI) ; current unit in SI
Mi         = 1.0           ; Ion mass in amu
Me         = 1/1836.15     ; Electron mass in amu

; conversion factors that are useful to calculate various derived quantities
common phys_convert, $
       ti0, cs0, mu0A, mu0, c0, uH0, op0, oc0, rg0, di0, ld0

ti0  = 1.0 ; ion temperature = ti0*p/rho*Mion
cs0  = 1.0 ; sound speed     = sqrt(cs0*gamma*p/rho)
c0   = 1.0 ; speed of light  = c0
mu0A = 1.0 ; Alfven speed    = sqrt(bb/mu0A/rho)
mu0  = 1.0 ; plasma beta     = p/(bb/2/mu0)
uH0  = 1.0 ; Hall velocity   = uH0*j/rho*Mion
op0  = 1.0 ; plasma freq.    = op0*sqrt(rho)/Mion
oc0  = 1.0 ; cyclotron freq. = oc0*b/mIon
rg0  = 1.0 ; ion gyro radius = rg0*sqrt(p/rho)/b*sqrt(Mion)
di0  = 1.0 ; inertial length = di0*sqrt(rho)*Mion
ld0  = 1.0 ; Debye length    = ld0*sqrt(p)/rho*Mion

; information obtained from the last file header
common file_head, $
   headline, it, time, gencoord, ndim, neqpar, nw, nx, eqpar, variables, $
   rbody

headline = '' ; first line often containing physcial unit names
it       = 0  ; time step
time     = 0. ; simulation time
gencoord = 0  ; true for unstructured/non-Cartesian grids
ndim     = 1  ; number of spatial dimensions
neqpar   = 0  ; number of scalar parameters
eqpar    = 0.0; values of scalar parameters
nw       = 1  ; number of variables
variables= '' ; names  of coordinates, variables, and scalar parameters
rbody    = 2.5; radius of the inner body

end

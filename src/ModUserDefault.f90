!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module ModUser
  ! This is the default user module which contains empty methods defined
  ! in ModUserEmpty.f90

  use ModUserEmpty

  include 'user_module.h' ! list of public methods

  real,              parameter :: VersionUserModule = 1.1
  character (len=*), parameter :: NameUserFile = 'src/ModUserDefault.f90'
  character (len=*), parameter :: NameUserModule = 'DEFAULT EMPTY ROUTINES'

end module ModUser
!==============================================================================

import { Ellipse_animation } from "./Ellipse_animation";

interface Button{
  index:number,
  offset_y:number,
  button_zoom_x:number,
  button_zoom_y:number,
  is_select: boolean,
  animator: Ellipse_animation
}


export class Center_Button implements Button{
  index: number = 0;
  offset_y: number = 0;
  button_zoom_x: number = 1;
  button_zoom_y: number = 1;
  is_select: boolean = false;
  animator: Ellipse_animation = new Ellipse_animation(100,50);
  constructor(index:number) {
    this.index = index;
    this.offset_y = 100;
  }


  select() : void {
    this.is_select = true;
    this.offset_y = 1100;
    this.button_zoom_x = 8;
    this.button_zoom_y = 8;
    this.animator.onPlay()
  }

  unselect(): void {
    this.is_select = false;
    this.offset_y = 100;
    this.button_zoom_x = 1;
    this.button_zoom_y = 1;
    this.animator.onPause()
  }

  get_selection() : boolean{
    return this.is_select;
  }

  change_selection(): void{
    this.is_select = !this.is_select
  }

}



